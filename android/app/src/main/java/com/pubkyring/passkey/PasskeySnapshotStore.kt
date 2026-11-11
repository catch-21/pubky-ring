package to.pubkyring.passkey

import android.content.Context
import java.io.File
import org.json.JSONObject

/**
 * Non-secret snapshot written by Ring's JS (src/passkey/snapshot.ts), so the provider
 * service can list pubkys without starting React Native.
 */
class PasskeySnapshotStore(context: Context) {
  data class Identity(val pubky: String, val name: String)

  private val file = File(context.noBackupFilesDir, "passkey_snapshot.json")

  fun write(json: String) {
    JSONObject(json)
    val temp = File(file.parentFile, "${file.name}.tmp")
    temp.writeText(json)
    if (!temp.renameTo(file)) {
      file.writeText(json)
      temp.delete()
    }
  }

  fun identities(): List<Identity> =
      try {
        val identities = JSONObject(file.readText()).optJSONArray("identities")
        (0 until (identities?.length() ?: 0)).mapNotNull { index ->
          val identity = identities!!.optJSONObject(index) ?: return@mapNotNull null
          val pubky = identity.optString("pubky")
          if (pubky.isEmpty()) null else Identity(pubky, identity.optString("name"))
        }
      } catch (e: Exception) {
        emptyList()
      }
}
