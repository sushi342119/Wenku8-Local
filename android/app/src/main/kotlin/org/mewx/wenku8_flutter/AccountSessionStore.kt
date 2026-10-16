package org.mewx.wenku8_flutter

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Device-bound session only: no password, export, log or Android backup. */
internal class AccountSessionStore(context: Context) {
    private val preferences = context.getSharedPreferences("wenku_account_session", Context.MODE_PRIVATE)
    private val alias = "wenku8.account.session.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun read(): String? = try {
        preferences.getString("sealed", null)?.let { sealed ->
            val parts = sealed.split(":")
            if (parts.size != 2) throw IllegalArgumentException()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
            cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)).toString(Charsets.UTF_8)
                .takeIf { Regex("[A-Za-z0-9,-]{8,256}").matches(it) }
        }
    } catch (_: Exception) {
        preferences.edit().clear().commit()
        null
    }
    fun write(cookie: String?) {
        require(cookie == null || Regex("[A-Za-z0-9,-]{8,256}").matches(cookie))
        val editor = preferences.edit()
        if (cookie == null) editor.clear() else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val iv = Base64.encodeToString(cipher.iv, Base64.NO_WRAP)
            val body = Base64.encodeToString(cipher.doFinal(cookie.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
            editor.putString("sealed", "$iv:$body")
        }
        check(editor.commit()) { "Session storage failed" }
    }
}
