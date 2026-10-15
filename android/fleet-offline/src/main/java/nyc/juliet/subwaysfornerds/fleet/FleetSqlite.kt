package nyc.juliet.subwaysfornerds.fleet

import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.driver.bundled.SQLITE_OPEN_CREATE
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READONLY
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READWRITE
import java.io.File

/** The bundled engine keeps JSON indexes/query semantics consistent on Android 12+. */
internal class FleetSqlite(file: File, readOnly: Boolean, private val check: () -> Unit = {}) : AutoCloseable {
	private val connection = BundledSQLiteDriver().open(file.path, if (readOnly) SQLITE_OPEN_READONLY else SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE)
	init {
		try { execute("PRAGMA trusted_schema=OFF"); if (readOnly) execute("PRAGMA query_only=ON") }
		catch (error: Exception) { connection.close(); throw error }
	}
	fun prepare(sql: String): SQLiteStatement { check(); return connection.prepare(sql) }
	fun execute(sql: String, values: List<String> = emptyList()) {
		prepare(sql).use { statement ->
			values.forEachIndexed { index, value -> statement.bindText(index + 1, value) }
			while (statement.step()) check()
		}
		check()
	}
	fun rows(sql: String, values: List<String> = emptyList()): List<List<String>> = prepare(sql).use { statement ->
		values.forEachIndexed { index, value -> statement.bindText(index + 1, value) }
		buildList {
			while (statement.step()) {
				check()
				add((0 until statement.getColumnCount()).map { if (statement.isNull(it)) "" else statement.getText(it) })
			}
		}
	}
	override fun close() { connection.close() }
}
