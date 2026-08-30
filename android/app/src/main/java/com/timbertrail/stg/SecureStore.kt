package com.timbertrail.stg

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec
import android.util.Base64

class SecureStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("stg-secure", Context.MODE_PRIVATE)
    private val alias = "stg-secure-store"
    private fun key(): java.security.Key {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        store.getKey(alias, null)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        return generator.generateKey()
    }
    fun put(name: String, value: String) { if (value.isEmpty()) { preferences.edit().remove(name).apply(); return }; val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, key()); val blob = cipher.iv + cipher.doFinal(value.toByteArray()); preferences.edit().putString(name, Base64.encodeToString(blob, Base64.NO_WRAP)).apply() }
    fun get(name: String): String { val encoded = preferences.getString(name, null) ?: return ""; return runCatching { val blob = Base64.decode(encoded, Base64.DEFAULT); val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob.copyOfRange(0, 12))); String(cipher.doFinal(blob.copyOfRange(12, blob.size))) }.getOrDefault("") }
}
