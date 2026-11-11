package to.pubkyring.passkey

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.credentials.CredentialManager
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import to.pubkyring.R

private const val ERROR_CODE = "pubky_passkey"

/** JS bridge for the passkey provider (src/passkey/native.ts). */
class PubkyPasskeyModule(private val reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "PubkyPasskey"

  private val providerSupported: Boolean
    get() =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            reactContext.resources.getBoolean(R.bool.credential_provider_supported)

  @ReactMethod
  fun writeSnapshot(json: String, promise: Promise) {
    try {
      PasskeySnapshotStore(reactContext).write(json)
      promise.resolve(true)
    } catch (e: Exception) {
      promise.reject(ERROR_CODE, e)
    }
  }

  @ReactMethod
  fun getProviderStatus(promise: Promise) {
    promise.resolve(
        Arguments.createMap().apply {
          putBoolean("supported", providerSupported)
          // Android has no public API that reports whether a provider is enabled.
          putNull("enabled")
          putBoolean("prfSupported", providerSupported)
        },
    )
  }

  @ReactMethod
  fun openProviderSettings(promise: Promise) {
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
        try {
          CredentialManager.create(reactContext).createSettingsPendingIntent().send()
          return promise.resolve(true)
        } catch (e: Exception) {
          val intent =
              Intent(Settings.ACTION_CREDENTIAL_PROVIDER)
                  .setData(Uri.parse("package:${reactContext.packageName}"))
                  .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
          reactContext.startActivity(intent)
          return promise.resolve(true)
        }
      }
      promise.resolve(false)
    } catch (e: Exception) {
      promise.reject(ERROR_CODE, e)
    }
  }

  private fun consentActivity(requestId: String): PasskeyConsentActivity? =
      (reactContext.currentActivity as? PasskeyConsentActivity)?.takeIf { it.matches(requestId) }

  @ReactMethod
  fun completeRequest(requestId: String, pubky: String, userVerified: Boolean, promise: Promise) {
    try {
      promise.resolve(consentActivity(requestId)?.complete(requestId, pubky, userVerified) ?: false)
    } catch (e: Exception) {
      promise.reject(ERROR_CODE, e)
    }
  }

  @ReactMethod
  fun cancelRequest(requestId: String, message: String, promise: Promise) {
    try {
      promise.resolve(consentActivity(requestId)?.cancel(requestId, message) ?: false)
    } catch (e: Exception) {
      promise.reject(ERROR_CODE, e)
    }
  }
}
