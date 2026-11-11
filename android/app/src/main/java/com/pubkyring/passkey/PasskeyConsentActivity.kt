package to.pubkyring.passkey

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.PendingIntentHandler
import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint.fabricEnabled
import com.facebook.react.defaults.DefaultReactActivityDelegate
import java.util.UUID

/**
 * Hosts the PubkyPasskeyConsent React Native surface (src/passkey/PasskeyConsentRoot.tsx)
 * inside the Credential Manager flow. Not exported: only the system's PendingIntent opens it.
 */
class PasskeyConsentActivity : ReactActivity() {
  private data class Pending(
      val requestId: String,
      val rpId: String,
      val pubky: String,
      val clientDataHash: ByteArray,
  )

  private var pending: Pending? = null
  private var launchOptions: Bundle? = null
  private var finished = false

  override fun getMainComponentName(): String = COMPONENT_NAME

  override fun createReactActivityDelegate(): ReactActivityDelegate =
      object : DefaultReactActivityDelegate(this, mainComponentName, fabricEnabled) {
        override fun getLaunchOptions(): Bundle? = this@PasskeyConsentActivity.launchOptions
      }

  override fun onCreate(savedInstanceState: Bundle?) {
    val error = prepare()
    super.onCreate(null)
    if (error != null) {
      Log.w(TAG, "Refusing passkey request: $error")
      finishWithError(error, cancelled = false)
    }
  }

  /** Returns an error message, or null once [pending] and [launchOptions] are set. */
  private fun prepare(): String? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return "Unsupported Android version"
    val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent) ?: return "Missing request"
    val pubky = intent.getStringExtra(EXTRA_PUBKY) ?: return "Missing pubky"
    val option =
        request.credentialOptions.filterIsInstance<GetPublicKeyCredentialOption>().firstOrNull()
            ?: return "Not a passkey request"
    val parsed = PubkyWebAuthn.parseRequest(option.requestJson) ?: return "Malformed request"
    if (!PubkyWebAuthn.isPubkyEnvelope(parsed.challenge)) return "Not a Pubky request"
    val clientDataHash = option.clientDataHash ?: return "Missing clientDataHash"
    val origin =
        try {
          request.callingAppInfo.getOrigin(privilegedBrowsers())
        } catch (e: Exception) {
          Log.w(TAG, "Origin check failed", e)
          null
        } ?: return "Caller is not an allowlisted browser"
    val originHost = Uri.parse(origin).host ?: return "Malformed origin"
    val requestId = UUID.randomUUID().toString()
    pending = Pending(requestId, parsed.rpId, pubky, clientDataHash)
    launchOptions =
        Bundle().apply {
          putString("requestId", requestId)
          putString("rpId", parsed.rpId)
          putString("originHost", originHost)
          putString("envelope", PubkyWebAuthn.encodeBase64Url(parsed.challenge))
          putString("pubky", pubky)
        }
    return null
  }

  private fun privilegedBrowsers(): String =
      assets.open(PRIVILEGED_BROWSERS_ASSET).bufferedReader().use { it.readText() }

  fun complete(requestId: String, pubky: String, userVerified: Boolean): Boolean {
    val request = pending ?: return false
    if (finished || request.requestId != requestId || request.pubky != pubky) return false
    val credentialId = PubkyWebAuthn.credentialId(request.rpId, pubky)
    val authenticatorData = PubkyWebAuthn.authenticatorData(request.rpId, userVerified)
    val signature = CeremonyKeyStore.sign(credentialId, authenticatorData, request.clientDataHash)
    val json = PubkyWebAuthn.assertionJson(credentialId, authenticatorData, signature, pubky)
    val result = Intent()
    PendingIntentHandler.setGetCredentialResponse(result, GetCredentialResponse(PublicKeyCredential(json)))
    finishWith(result)
    return true
  }

  fun cancel(requestId: String, message: String): Boolean {
    if (finished || pending?.requestId != requestId) return false
    finishWithError(message, cancelled = true)
    return true
  }

  fun matches(requestId: String): Boolean = pending?.requestId == requestId

  private fun finishWithError(message: String, cancelled: Boolean) {
    val result = Intent()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
      PendingIntentHandler.setGetCredentialException(
          result,
          if (cancelled) GetCredentialCancellationException(message) else GetCredentialUnknownException(message),
      )
    }
    finishWith(result)
  }

  private fun finishWith(result: Intent) {
    if (finished) return
    finished = true
    runOnUiThread {
      setResult(RESULT_OK, result)
      finish()
    }
  }

  companion object {
    const val COMPONENT_NAME = "PubkyPasskeyConsent"
    const val EXTRA_PUBKY = "to.pubkyring.passkey.PUBKY"
    private const val PRIVILEGED_BROWSERS_ASSET = "passkey_privileged_browsers.json"
    private const val TAG = "PubkyPasskey"
  }
}
