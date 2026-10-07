import AuthenticationServices
import Foundation
import GoogleSignIn
import Observation
import Security
import TransitCore
import UIKit

struct NerdsAccount: Decodable {
	struct Identity: Decodable, Identifiable { let provider: String; let email: String?; var id: String { provider } }
	let id: String
	let identities: [Identity]
}
private struct AccountConfiguration: Decodable { let enabled: Bool; let googleClientID: String?; let googleServerClientID: String? }
private struct AccountResponse: Decodable { let account: NerdsAccount; let token: String? }
struct AccountSettingsRevision: Codable { let revision: Int; let settings: PortableSettings? }
private struct LoginChallenge: Decodable { let id: String; let nonce: String }
private struct EmptyResponse: Decodable {}
private struct AccountFailure: LocalizedError {
	let code: Int
	let message: String
	var errorDescription: String? { message }
}
private struct SessionVault {
	let service: String
	private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"] }
	func read() -> String? {
		var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
		var result: CFTypeRef?
		guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}
	func write(_ token: String?) throws {
		guard let token else { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError.message("Could not clear your saved session.") }; return }
		let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
		var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
		if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil) }
		guard status == errSecSuccess else { throw SettingsError.message("Your sign-in could not be saved securely. Please try again.") }
	}
}
@MainActor @Observable
final class AccountModel {
	var enabled = false
	var ready = false
	var account: NerdsAccount?
	var status = "Not signed in"
	var error: String?
	var first: AccountSettingsRevision?
	var conflicts: [SettingsConflict] = []
	var signingIn = false
	@ObservationIgnored private var configuration: AccountConfiguration?
	@ObservationIgnored private weak var app: AppModel?
	@ObservationIgnored private let baseURL: URL
	@ObservationIgnored private let vault: SessionVault
	@ObservationIgnored private let session: URLSession
	@ObservationIgnored private var token: String?
	@ObservationIgnored private var generation = 0
	@ObservationIgnored private var syncing = false
	@ObservationIgnored private var debounce: Task<Void, Never>?
	@ObservationIgnored private var lastObservedSettings: PortableSettings?
	@ObservationIgnored private var conflictBase: PortableSettings?
	@ObservationIgnored private var conflictRemote: AccountSettingsRevision?
	@ObservationIgnored private let apple = AppleAccountLogin()
	init() {
		#if DEBUG
		let environment = ProcessInfo.processInfo.environment
		baseURL = (environment["SFN_AUTH_BASE_URL"] ?? environment["SFN_API_BASE_URL"]).flatMap(URL.init(string:)) ?? TransitAPI.productionBaseURL
		#else
		baseURL = TransitAPI.productionBaseURL
		#endif
		vault = SessionVault(service: "nyc.juliet.subwaysfornerds.account." + baseURL.absoluteString)
		token = vault.read()
		let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
		config.timeoutIntervalForRequest = 15; session = URLSession(configuration: config)
	}
	func run(app: AppModel) async {
		self.app = app
		lastObservedSettings = app.portableSettings
		app.settingsDidChange = { [weak self] in self?.changed() }
		await refreshAccount()
		while !Task.isCancelled {
			await sync()
			do { try await Task.sleep(for: .seconds(30)) } catch { return }
		}
	}
	func reconnect() async { await refreshAccount(); await sync() }
	private func refreshAccount() async {
		let runGeneration = generation
		do {
			let config: AccountConfiguration = try await request("auth/config")
			guard runGeneration == generation, !Task.isCancelled else { return }
			configuration = config; enabled = config.enabled; ready = true
			guard enabled else { return }
			if token != nil {
				let result: AccountResponse = try await request("account")
				guard runGeneration == generation, !Task.isCancelled else { return }
				account = result.account
			}
		} catch {
			guard runGeneration == generation, !Task.isCancelled else { return }; ready = true
			if (error as? AccountFailure)?.code == 401 { invalidateSession() }
			else { self.error = "Account service unavailable. Settings are saved on this device." }
		}
	}
	private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> T {
		var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method; request.httpBody = body
		request.cachePolicy = .reloadIgnoringLocalCacheData; request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
		if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
		if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
		for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
		let (data, response) = try await session.data(for: request)
		guard let response = response as? HTTPURLResponse else { throw SettingsError.message("Account service unavailable.") }
		guard (200...299).contains(response.statusCode) else {
			let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"] ?? "Could not sync settings."
			throw AccountFailure(code: response.statusCode, message: message)
		}
		return try JSONDecoder().decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data)
	}
	func changed() {
		guard let app, account != nil, lastObservedSettings != app.portableSettings else { return }
		lastObservedSettings = app.portableSettings
		status = "Changes waiting to sync"; debounce?.cancel()
		debounce = Task { [weak self] in
			do { try await Task.sleep(for: .seconds(1)) } catch { return }; await self?.sync()
		}
	}
	func login(_ provider: String, intent: String = "login") async {
		guard enabled, !signingIn else { return }; signingIn = true; generation += 1; defer { signingIn = false }
		do {
			let challenge: LoginChallenge = try await request("auth/challenges", method: "POST", body: JSONSerialization.data(withJSONObject: ["provider": provider, "platform": "native", "intent": intent]))
			let identityToken: String, code: String
			if provider == "apple" {
				let result = try await apple.signIn(nonce: challenge.nonce); identityToken = result.token; code = result.code
			} else {
				guard let clientID = configuration?.googleClientID, let serverID = configuration?.googleServerClientID, let controller = Self.presentingController else { throw SettingsError.message("Google sign-in is not configured for this build.") }
				let expectedScheme = clientID.split(separator: ".").reversed().joined(separator: ".")
				let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
				guard types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(expectedScheme) == true }) else { throw SettingsError.message("Google sign-in needs its callback configured in this app build.") }
				GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverID)
				let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller, hint: nil, additionalScopes: nil, nonce: challenge.nonce)
				guard let idToken = result.user.idToken?.tokenString, let authCode = result.serverAuthCode else { throw SettingsError.message("Google did not return a complete sign-in. Please try again.") }
				identityToken = idToken; code = authCode
			}
			let result: AccountResponse = try await request("auth/" + provider + "/exchange", method: "POST", body: JSONSerialization.data(withJSONObject: ["challenge": challenge.id, "identityToken": identityToken, "code": code]))
			if let sessionToken = result.token ?? token { try vault.write(sessionToken); token = sessionToken }
			generation += 1; account = result.account; error = nil; first = nil; conflicts = []; conflictBase = nil; conflictRemote = nil
			signingIn = false; await sync()
		} catch {
			let failure = error as NSError
			if failure.domain == ASAuthorizationError.errorDomain && failure.code == ASAuthorizationError.canceled.rawValue { return }
			if failure.domain == kGIDSignInErrorDomain && failure.code == GIDSignInError.canceled.rawValue { return }
			self.error = error.localizedDescription
		}
	}
	static var presentingController: UIViewController? {
		let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
		let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
		var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
		while let next = controller?.presentedViewController { controller = next }; return controller
	}
	func handle(_ url: URL) -> Bool {
		let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
		let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
		guard let scheme = url.scheme, scheme.hasPrefix("com.googleusercontent.apps."), schemes.contains(scheme) else { return false }
		return GIDSignIn.sharedInstance.handle(url)
	}
	func logout() async {
		do { let _: EmptyResponse = try await request("auth/logout", method: "POST"); try disconnect() } catch {
			if (error as? AccountFailure)?.code == 401 { do { try disconnect() } catch { self.error = error.localizedDescription } }
			else { self.error = error.localizedDescription }
		}
	}
	func remove(provider: String? = nil) async {
		do { let _: EmptyResponse = try await request("account" + (provider.map { "/identities/" + $0 } ?? ""), method: "DELETE"); try disconnect() } catch { self.error = error.localizedDescription }
	}
	private func disconnect() throws {
		try vault.write(nil); token = nil; generation += 1; debounce?.cancel(); GIDSignIn.sharedInstance.signOut()
		account = nil; first = nil; conflicts = []; conflictBase = nil; conflictRemote = nil; status = "Not signed in"; error = nil
		if let app { try app.acceptSettings(app.portableSettings, sync: nil) }
	}
	private func invalidateSession() {
		try? vault.write(nil); token = nil; account = nil; generation += 1
		status = "Sign in again to sync. Changes are saved on this device."
	}
	func chooseInitial(remote: Bool) async {
		guard let first, let settings = first.settings, let account, let app else { return }
		do {
			try app.acceptSettings(remote ? settings : app.portableSettings, sync: SettingsSyncState(userID: account.id, baseline: settings, revision: first.revision))
			self.first = nil; error = nil; await sync()
		} catch { self.error = error.localizedDescription }
	}
	func resolve(_ choices: [String: String]) async {
		guard let base = conflictBase, let remote = conflictRemote, let settings = remote.settings, let account, let app else { return }
		do {
			let merged = try SettingsMerge.merge(base: base, local: app.portableSettings, remote: settings, choices: choices)
			guard merged.conflicts.isEmpty else { conflicts = merged.conflicts; return }
			try app.acceptSettings(merged.settings, sync: SettingsSyncState(userID: account.id, baseline: settings, revision: remote.revision))
			conflicts = []; conflictBase = nil; conflictRemote = nil; error = nil; await sync()
		} catch { self.error = error.localizedDescription }
	}
	func sync() async {
		guard let account, let app, !syncing, !signingIn, first == nil, conflicts.isEmpty else { return }
		guard app.connected else { status = "Offline — changes saved on this device"; return }
		syncing = true; defer { syncing = false }; let requestGeneration = generation
		do {
			status = "Syncing…"; error = nil
			let remote: AccountSettingsRevision = try await request("account/settings")
			guard requestGeneration == generation, !Task.isCancelled else { return }
			if let message = app.settingsError { throw SettingsError.message(message) }
			let local = app.portableSettings
			let baseline = app.settingsSync?.userID == account.id ? app.settingsSync?.baseline : nil
			if baseline == nil, let settings = remote.settings, settings != local { first = remote; status = "Choose settings to start syncing"; return }
			let merged: SettingsMerge
			if let baseline, let settings = remote.settings { merged = try SettingsMerge.merge(base: baseline, local: local, remote: settings) }
			else { merged = try SettingsMerge.merge(base: local, local: local, remote: local) }
			if !merged.conflicts.isEmpty { conflictBase = baseline; conflictRemote = remote; conflicts = merged.conflicts; status = "Choose which changes to keep"; return }
			let accepted: AccountSettingsRevision
			if merged.settings == remote.settings { accepted = remote }
			else { accepted = try await request("account/settings", method: "PUT", body: JSONEncoder().encode(merged.settings), headers: ["If-Match": "\"\(remote.revision)\""]) }
			guard requestGeneration == generation, !Task.isCancelled, let settings = accepted.settings else { return }
			let rebase = try SettingsMerge.merge(base: local, local: app.portableSettings, remote: settings)
			try app.acceptSettings(rebase.settings, sync: SettingsSyncState(userID: account.id, baseline: settings, revision: accepted.revision))
			lastObservedSettings = rebase.settings
			if !rebase.conflicts.isEmpty { conflictBase = local; conflictRemote = accepted; conflicts = rebase.conflicts; status = "Choose which changes to keep" }
			else { status = rebase.settings == settings ? "Settings synced" : "Changes waiting to sync" }
		} catch {
			guard requestGeneration == generation, !Task.isCancelled else { return }
			if (error as? AccountFailure)?.code == 401 { invalidateSession() }
			else if (error as? AccountFailure)?.code == 412 {
				status = "New account changes — retrying…"
				debounce?.cancel(); debounce = Task { [weak self] in
					do { try await Task.sleep(for: .seconds(1)) } catch { return }; await self?.sync()
				}
			}
			else { status = "Changes saved on this device"; self.error = error.localizedDescription }
		}
	}
}
@MainActor
private final class AppleAccountLogin: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
	private var continuation: CheckedContinuation<(token: String, code: String), any Error>?
	private var controller: ASAuthorizationController?
	private var anchor: ASPresentationAnchor?
	func signIn(nonce: String) async throws -> (token: String, code: String) {
		guard let window = AccountModel.presentingController?.view.window else { throw SettingsError.message("Open the app to sign in with Apple.") }
		anchor = window
		return try await withCheckedThrowingContinuation { continuation in
			self.continuation = continuation
			let request = ASAuthorizationAppleIDProvider().createRequest(); request.requestedScopes = [.email]; request.nonce = nonce
			let controller = ASAuthorizationController(authorizationRequests: [request]); self.controller = controller
			controller.delegate = self; controller.presentationContextProvider = self; controller.performRequests()
		}
	}
	func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
		anchor ?? ASPresentationAnchor()
	}
	func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
		defer { continuation = nil; self.controller = nil; anchor = nil }
		guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
			let tokenData = credential.identityToken, let codeData = credential.authorizationCode,
			let token = String(data: tokenData, encoding: .utf8), let code = String(data: codeData, encoding: .utf8) else {
			continuation?.resume(throwing: SettingsError.message("Apple did not return a complete sign-in.")); return
		}
		continuation?.resume(returning: (token, code))
	}
	func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
		continuation?.resume(throwing: error); continuation = nil; self.controller = nil; anchor = nil
	}
}
