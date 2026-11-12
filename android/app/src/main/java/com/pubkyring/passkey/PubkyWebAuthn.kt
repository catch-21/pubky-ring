package to.pubkyring.passkey

import android.util.Base64
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.json.JSONObject

/**
 * WebAuthn helpers for the Pubky passkey provider (docs/passkey-provider/PLAN.md).
 * The envelope layout and credential ID derivation must match src/passkey/envelope.ts
 * and scripts/passkey/protocol-reference.js.
 */
object PubkyWebAuthn {
  private val ENVELOPE_MAGIC = "PKYWA1".toByteArray(Charsets.US_ASCII)
  private const val FLAG_USER_PRESENT = 0x01
  private const val FLAG_USER_VERIFIED = 0x04

  data class Request(val rpId: String, val challenge: ByteArray)

  /** Reads rpId and challenge from a WebAuthn get() request JSON. Null if either is missing. */
  fun parseRequest(requestJson: String): Request? =
      try {
        val json = JSONObject(requestJson)
        val rpId = json.optString("rpId")
        val challenge = json.optString("challenge")
        if (rpId.isEmpty() || challenge.isEmpty()) null else Request(rpId, decodeBase64Url(challenge))
      } catch (e: Exception) {
        null
      }

  fun isPubkyEnvelope(bytes: ByteArray): Boolean =
      bytes.size > ENVELOPE_MAGIC.size && ENVELOPE_MAGIC.indices.all { bytes[it] == ENVELOPE_MAGIC[it] }

  fun credentialId(rpId: String, pubky: String): ByteArray {
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update("pubky-ring-credential-v1".toByteArray(Charsets.UTF_8))
    digest.update(0)
    digest.update(rpId.toByteArray(Charsets.UTF_8))
    digest.update(0)
    digest.update(pubky.toByteArray(Charsets.UTF_8))
    return digest.digest().copyOf(16)
  }

  /** rpIdHash | flags | signCount (always 0: ceremony keys never leave the device). */
  fun authenticatorData(rpId: String, userVerified: Boolean): ByteArray {
    val rpIdHash = MessageDigest.getInstance("SHA-256").digest(rpId.toByteArray(Charsets.UTF_8))
    val flags = FLAG_USER_PRESENT or (if (userVerified) FLAG_USER_VERIFIED else 0)
    return ByteBuffer.allocate(rpIdHash.size + 1 + 4).put(rpIdHash).put(flags.toByte()).putInt(0).array()
  }

  /**
   * Assertion JSON for PublicKeyCredential. Chrome supplies its own clientDataJSON when it
   * passed a clientDataHash, so the field is a placeholder, as Android's provider guide describes.
   */
  fun assertionJson(
      credentialId: ByteArray,
      authenticatorData: ByteArray,
      signature: ByteArray,
      pubky: String,
  ): String {
    val id = encodeBase64Url(credentialId)
    val response =
        JSONObject()
            .put("clientDataJSON", encodeBase64Url("{}".toByteArray(Charsets.UTF_8)))
            .put("authenticatorData", encodeBase64Url(authenticatorData))
            .put("signature", encodeBase64Url(signature))
            .put("userHandle", encodeBase64Url(pubky.toByteArray(Charsets.UTF_8)))
    return JSONObject()
        .put("id", id)
        .put("rawId", id)
        .put("type", "public-key")
        .put("authenticatorAttachment", "platform")
        .put("response", response)
        .put("clientExtensionResults", JSONObject())
        .toString()
  }

  fun encodeBase64Url(bytes: ByteArray): String =
      Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

  fun decodeBase64Url(value: String): ByteArray =
      Base64.decode(value, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
}
