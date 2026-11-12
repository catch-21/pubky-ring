package to.pubkyring.passkey

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Per-(rpId, pubky) ES256 "ceremony keys" in the Android Keystore. They only complete the
 * WebAuthn ceremony; the Pubky grant signed with the pubky key is the real credential.
 */
object CeremonyKeyStore {
  private const val PROVIDER = "AndroidKeyStore"
  private const val ALIAS_PREFIX = "pubky-passkey-"

  private fun alias(credentialId: ByteArray) = ALIAS_PREFIX + PubkyWebAuthn.encodeBase64Url(credentialId)

  private fun privateKey(credentialId: ByteArray): PrivateKey {
    val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
    val alias = alias(credentialId)
    (keyStore.getKey(alias, null) as? PrivateKey)?.let {
      return it
    }
    val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER)
    generator.initialize(
        KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build(),
    )
    return generator.generateKeyPair().private
  }

  /** DER-encoded ECDSA P-256 signature over authenticatorData || clientDataHash. */
  fun sign(credentialId: ByteArray, authenticatorData: ByteArray, clientDataHash: ByteArray): ByteArray =
      Signature.getInstance("SHA256withECDSA").run {
        initSign(privateKey(credentialId))
        update(authenticatorData)
        update(clientDataHash)
        sign()
      }
}
