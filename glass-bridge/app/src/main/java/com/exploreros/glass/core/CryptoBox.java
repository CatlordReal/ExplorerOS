package com.exploreros.glass.core;

import java.nio.charset.Charset;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** AES-256-GCM packet cipher required by Explorer Link v1. */
public final class CryptoBox {
    public static final byte[] AAD = "ExplorerLink/1".getBytes(Charset.forName("US-ASCII"));
    private static final int NONCE_BYTES = 12, TAG_BYTES = 16;
    private final byte[] key; private final SecureRandom random;
    public CryptoBox(byte[] key) throws ProtocolException { this(key, new SecureRandom()); }
    CryptoBox(byte[] key, SecureRandom random) throws ProtocolException { if (key == null || key.length != 32) throw new ProtocolException("pairing key must be 32 bytes"); this.key = key.clone(); this.random = random; }
    public Packet seal(byte[] plaintext) throws ProtocolException { byte[] nonce = new byte[NONCE_BYTES]; random.nextBytes(nonce); return seal(nonce, plaintext); }
    public Packet seal(byte[] nonce, byte[] plaintext) throws ProtocolException { if (nonce == null || nonce.length != NONCE_BYTES) throw new ProtocolException("bad nonce"); try { Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BYTES * 8, nonce)); cipher.updateAAD(AAD); return new Packet(nonce.clone(), cipher.doFinal(plaintext)); } catch (GeneralSecurityException e) { throw new ProtocolException("encryption failed", e); } }
    public byte[] open(byte[] nonce, byte[] box) throws ProtocolException { if (nonce == null || nonce.length != NONCE_BYTES || box == null || box.length < TAG_BYTES) throw new ProtocolException("bad encrypted frame"); try { Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BYTES * 8, nonce)); cipher.updateAAD(AAD); return cipher.doFinal(box); } catch (GeneralSecurityException e) { throw new ProtocolException("authentication failed", e); } }
    public static final class Packet { public final byte[] nonce, box; Packet(byte[] nonce, byte[] box) { this.nonce = nonce; this.box = box; } }
}
