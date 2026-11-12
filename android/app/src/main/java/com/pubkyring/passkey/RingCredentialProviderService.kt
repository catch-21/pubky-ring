package to.pubkyring.passkey

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CredentialEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.ProviderClearCredentialStateRequest
import androidx.credentials.provider.PublicKeyCredentialEntry
import to.pubkyring.R

private const val TAG = "PubkyPasskey"

/**
 * Offers one passkey entry per pubky, but only for WebAuthn get() requests whose challenge
 * is a Pubky envelope. Everything else (ordinary passkeys, passwords, registration) gets an
 * empty response, so Ring never appears for sites that are not asking for a Pubky sign-in.
 */
@RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
class RingCredentialProviderService : CredentialProviderService() {

  override fun onBeginGetCredentialRequest(
      request: BeginGetCredentialRequest,
      cancellationSignal: CancellationSignal,
      callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
  ) {
    val identities by lazy { PasskeySnapshotStore(this).identities() }
    val entries = mutableListOf<CredentialEntry>()
    val options = request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>()
    var envelopes = 0
    options.forEach { option ->
      val parsed = PubkyWebAuthn.parseRequest(option.requestJson) ?: return@forEach
      if (!PubkyWebAuthn.isPubkyEnvelope(parsed.challenge)) return@forEach
      envelopes++
      identities.forEach { identity ->
        entries.add(entryFor(option, identity))
      }
    }
    if (envelopes > 0) {
      Log.d(TAG, "Pubky request: ${entries.size} entries for ${identities.size} identities")
    }
    callback.onResult(BeginGetCredentialResponse(credentialEntries = entries))
  }

  private fun entryFor(
      option: BeginGetPublicKeyCredentialOption,
      identity: PasskeySnapshotStore.Identity,
  ): CredentialEntry {
    val intent =
        Intent(this, PasskeyConsentActivity::class.java)
            .setPackage(packageName)
            .putExtra(PasskeyConsentActivity.EXTRA_PUBKY, identity.pubky)
    val pendingIntent =
        PendingIntent.getActivity(
            this,
            identity.pubky.hashCode(),
            intent,
            // The system fills in the provider request, so the intent must be mutable.
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    val shortPubky = shorten(identity.pubky)
    return PublicKeyCredentialEntry.Builder(
            this,
            identity.name.ifBlank { shortPubky },
            pendingIntent,
            option,
        )
        .setDisplayName(getString(R.string.passkey_entry_subtitle, shortPubky))
        .setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
        .build()
  }

  override fun onBeginCreateCredentialRequest(
      request: BeginCreateCredentialRequest,
      cancellationSignal: CancellationSignal,
      callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
  ) {
    callback.onResult(BeginCreateCredentialResponse())
  }

  override fun onClearCredentialStateRequest(
      request: ProviderClearCredentialStateRequest,
      cancellationSignal: CancellationSignal,
      callback: OutcomeReceiver<Void?, ClearCredentialException>,
  ) {
    callback.onResult(null)
  }

  private fun shorten(pubky: String) = if (pubky.length <= 12) pubky else "${pubky.take(6)}…${pubky.takeLast(6)}"
}
