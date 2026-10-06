import SwiftUI
import AuthenticationServices
import UIKit
import GoogleSignInSwift

struct AccountSettingsSection: View {
	@Environment(AppModel.self) private var app
	@Environment(AccountModel.self) private var account
	@State private var choices: [String: String] = [:]
	@State private var confirmDelete = false
	@State private var unlink: String?
	var body: some View {
		Section {
			if !account.ready { Text("Checking account availability…").font(.footnote) }
			else if !account.enabled { Text("Sign-in is currently unavailable. You can still move settings with a .nerds file.").font(.footnote) }
			else if let user = account.account {
				Text(account.status).font(.footnote).accessibilityIdentifier("syncStatus")
				ForEach(user.identities) { identity in
					VStack(alignment: .leading) {
						Text(identity.provider.capitalized + " · " + (identity.email ?? "Connected")).font(.subheadline)
						if user.identities.count > 1 { Button("Unlink " + identity.provider.capitalized, role: .destructive) { unlink = identity.provider } }
					}
				}
				ForEach(["apple", "google"].filter { provider in !user.identities.contains { $0.provider == provider } }, id: \.self) { provider in
					Button("Link " + provider.capitalized) { Task { await account.login(provider, intent: "link") } }.disabled(account.signingIn)
				}
				if let first = account.first, let settings = first.settings {
					Text("Choose settings to start syncing").font(.headline)
					SettingsChangesView(from: app.portableSettings, to: settings)
					Button("Use this device’s settings") { Task { await account.chooseInitial(remote: false) } }
					Button("Use account settings") { Task { await account.chooseInitial(remote: true) } }
				}
				if !account.conflicts.isEmpty {
					Text("Choose which changes to keep").font(.headline)
					ForEach(account.conflicts) { conflict in
						VStack(alignment: .leading) {
							Text(settingsLabel(conflict.path, app: app)).font(.subheadline)
							Picker("Keep", selection: Binding(get: { choices[conflict.path] ?? "" }, set: { choices[conflict.path] = $0 })) {
								Text("Choose a value").tag("")
								Text("This device: " + settingsValue(conflict.local)).tag("local")
								Text("Account: " + settingsValue(conflict.remote)).tag("remote")
							}
						}
					}
					Button("Save choices") { Task { await account.resolve(choices) } }.disabled(account.conflicts.contains { choices[$0.path] == nil })
				}
				Button("Sync now") { Task { await account.sync() } }
				Button("Sign out") { Task { await account.logout() } }
				Button("Delete account", role: .destructive) { confirmDelete = true }
			} else {
				Text("Sign in to keep your settings across devices, or continue using the app without an account.").font(.footnote)
				NativeAppleSignInButton { Task { await account.login("apple") } }
					.frame(height: 44).disabled(account.signingIn).accessibilityIdentifier("signInApple")
				GoogleSignInButton { Task { await account.login("google") } }.disabled(account.signingIn).accessibilityIdentifier("signInGoogle")
			}
			if let error = account.error {
				Text(error).font(.footnote).foregroundStyle(.red)
				if let user = account.account {
					ForEach(user.identities) { identity in Button("Verify again with " + identity.provider.capitalized) { Task { await account.login(identity.provider, intent: "reauth") } } }
				}
			}
			Link("Privacy", destination: URL(string: "https://juliet.nyc/subwaysForNerds/privacy.html")!)
		} header: { ListHeader("Account and sync") } footer: { Text("Your current station stays separate on each device. Signing out keeps local settings.") }
		.confirmationDialog("Delete your account and all synced settings?", isPresented: $confirmDelete, titleVisibility: .visible) {
			Button("Delete account", role: .destructive) { Task { await account.remove() } }
		} message: { Text("Settings already on devices will remain there.") }
		.confirmationDialog("Unlink " + (unlink?.capitalized ?? "login") + "?", isPresented: Binding(get: { unlink != nil }, set: { if !$0 { unlink = nil } }), titleVisibility: .visible) {
			Button("Unlink", role: .destructive) {
				guard let provider = unlink else { return }
				unlink = nil; Task { await account.remove(provider: provider) }
			}
		} message: { Text("You will be signed out on all devices. Sign in with your remaining login method.") }
	}
}

private struct NativeAppleSignInButton: UIViewRepresentable {
	let action: () -> Void
	func makeCoordinator() -> Coordinator { Coordinator(action: action) }
	func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
		let button = ASAuthorizationAppleIDButton(authorizationButtonType: .continue, authorizationButtonStyle: .black)
		button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
		return button
	}
	func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action }
	@MainActor final class Coordinator: NSObject {
		var action: () -> Void
		init(action: @escaping () -> Void) { self.action = action }
		@objc func pressed() { action() }
	}
}
