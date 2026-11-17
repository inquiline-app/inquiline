package io.github.inquiline.notifications;

import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

/**
 * Makes a certificate for each site the ad blocker opens, signed by this Mac's own authority
 * (made by Inquiline for this Mac alone, trusted only inside its Android). Written out in DER by
 * hand, as Android gives apps no certificate builder.
 */
final class Certs {
    final X509Certificate authority;
    private final PrivateKey authorityKey;
    /** One key for every site's certificate: making a new RSA key takes a while. */
    final KeyPair siteKey;
    private final SecureRandom random = new SecureRandom();

    /**
     * This installation's own authority, made the first time in the helper's private files
     * (ca.pem, ca.key) and kept: its key never leaves them. Also writes ca.name, the file name
     * Android's certificate stores give it (OpenSSL's old subject hash), for Inquiline to install it.
     */
    static Certs ofInstallation(java.io.File dir) throws Exception {
        java.io.File pem = new java.io.File(dir, "ca.pem"), key = new java.io.File(dir, "ca.key");
        if (!pem.exists() || !key.exists()) {
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            KeyPair pair = generator.generateKeyPair();
            byte[] name = seq(set(seq(oid(new int[] {2, 5, 4, 3}), tlv(0x0C, "Inquiline Ad Blocking".getBytes(StandardCharsets.UTF_8)))),
                    set(seq(oid(new int[] {2, 5, 4, 10}), tlv(0x0C, "Inquiline".getBytes(StandardCharsets.UTF_8)))));
            byte[] sha256WithRsa = seq(oid(new int[] {1, 2, 840, 113549, 1, 1, 11}), new byte[] {0x05, 0x00});
            long now = System.currentTimeMillis();
            byte[] validity = seq(utcTime(new Date(now - 86_400_000L)), utcTime(new Date(now + 3650L * 86_400_000L)));
            byte[] basic = seq(oid(new int[] {2, 5, 29, 19}), new byte[] {0x01, 0x01, (byte) 0xFF},
                    tlv(0x04, seq(new byte[] {0x01, 0x01, (byte) 0xFF})));
            byte[] usage = seq(oid(new int[] {2, 5, 29, 15}), new byte[] {0x01, 0x01, (byte) 0xFF},
                    tlv(0x04, tlv(0x03, new byte[] {0x01, 0x06})));
            byte[] tbs = seq(tlv(0xA0, integer(BigInteger.valueOf(2))), integer(new BigInteger(64, new SecureRandom()).add(BigInteger.ONE)),
                    sha256WithRsa, name, validity, name, pair.getPublic().getEncoded(), tlv(0xA3, seq(basic, usage)));
            Signature signer = Signature.getInstance("SHA256withRSA");
            signer.initSign(pair.getPrivate());
            signer.update(tbs);
            byte[] signature = signer.sign();
            byte[] bits = new byte[signature.length + 1];
            System.arraycopy(signature, 0, bits, 1, signature.length);
            byte[] der = seq(tbs, sha256WithRsa, tlv(0x03, bits));
            String text = "-----BEGIN CERTIFICATE-----\n"
                    + java.util.Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.US_ASCII)).encodeToString(der)
                    + "\n-----END CERTIFICATE-----\n";
            java.nio.file.Files.write(key.toPath(), pair.getPrivate().getEncoded());
            java.nio.file.Files.write(pem.toPath(), text.getBytes(StandardCharsets.US_ASCII));
        }
        Certs certs = new Certs(java.nio.file.Files.readAllBytes(pem.toPath()), java.nio.file.Files.readAllBytes(key.toPath()));
        byte[] md5 = java.security.MessageDigest.getInstance("MD5").digest(certs.authority.getSubjectX500Principal().getEncoded());
        String hash = String.format(Locale.US, "%02x%02x%02x%02x", md5[3], md5[2], md5[1], md5[0]);
        java.nio.file.Files.write(new java.io.File(dir, "ca.name").toPath(), (hash + ".0").getBytes(StandardCharsets.US_ASCII));
        return certs;
    }

    Certs(byte[] authorityPem, byte[] authorityKeyPkcs8) throws Exception {
        authority = (X509Certificate) CertificateFactory.getInstance("X.509")
                .generateCertificate(new java.io.ByteArrayInputStream(authorityPem));
        authorityKey = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(authorityKeyPkcs8));
        KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        siteKey = generator.generateKeyPair();
    }

    X509Certificate forHost(String host) throws Exception {
        byte[] sha256WithRsa = seq(oid(new int[] {1, 2, 840, 113549, 1, 1, 11}), new byte[] {0x05, 0x00});
        long now = System.currentTimeMillis();
        byte[] validity = seq(utcTime(new Date(now - 86_400_000L)), utcTime(new Date(now + 300L * 86_400_000L)));
        byte[] subject = seq(set(seq(oid(new int[] {2, 5, 4, 3}), tlv(0x0C, host.getBytes(StandardCharsets.UTF_8)))));
        byte[] san = seq(oid(new int[] {2, 5, 29, 17}),
                tlv(0x04, seq(isIp(host) ? tlv(0x87, ipBytes(host)) : tlv(0x82, host.getBytes(StandardCharsets.US_ASCII)))));
        byte[] basic = seq(oid(new int[] {2, 5, 29, 19}), new byte[] {0x01, 0x01, (byte) 0xFF}, tlv(0x04, seq()));
        byte[] serverAuth = seq(oid(new int[] {2, 5, 29, 37}), tlv(0x04, seq(oid(new int[] {1, 3, 6, 1, 5, 5, 7, 3, 1}))));
        byte[] extensions = tlv(0xA3, seq(san, basic, serverAuth));
        byte[] tbs = seq(tlv(0xA0, integer(BigInteger.valueOf(2))), integer(new BigInteger(64, random).abs().add(BigInteger.ONE)),
                sha256WithRsa, authority.getSubjectX500Principal().getEncoded(), validity, subject,
                siteKey.getPublic().getEncoded(), extensions);
        Signature signer = Signature.getInstance("SHA256withRSA");
        signer.initSign(authorityKey);
        signer.update(tbs);
        byte[] signature = signer.sign();
        byte[] bits = new byte[signature.length + 1];
        System.arraycopy(signature, 0, bits, 1, signature.length);
        byte[] der = seq(tbs, sha256WithRsa, tlv(0x03, bits));
        return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(new java.io.ByteArrayInputStream(der));
    }

    private static boolean isIp(String host) {
        return host.matches("\\d+\\.\\d+\\.\\d+\\.\\d+");
    }

    private static byte[] ipBytes(String host) {
        String[] parts = host.split("\\.");
        byte[] out = new byte[4];
        for (int i = 0; i < 4; i++) out[i] = (byte) Integer.parseInt(parts[i]);
        return out;
    }

    private static byte[] utcTime(Date date) {
        SimpleDateFormat format = new SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("UTC"));
        return tlv(0x17, format.format(date).getBytes(StandardCharsets.US_ASCII));
    }

    private static byte[] integer(BigInteger value) {
        return tlv(0x02, value.toByteArray());
    }

    private static byte[] oid(int[] parts) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(parts[0] * 40 + parts[1]);
        for (int i = 2; i < parts.length; i++) {
            int value = parts[i];
            byte[] chunk = new byte[5];
            int n = 0;
            do {
                chunk[n++] = (byte) (value & 0x7F);
                value >>>= 7;
            } while (value != 0);
            for (int j = n - 1; j >= 0; j--) out.write(chunk[j] | (j > 0 ? 0x80 : 0));
        }
        return tlv(0x06, out.toByteArray());
    }

    private static byte[] seq(byte[]... parts) {
        return tlv(0x30, concat(parts));
    }

    private static byte[] set(byte[]... parts) {
        return tlv(0x31, concat(parts));
    }

    private static byte[] concat(byte[]... parts) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte[] part : parts) out.write(part, 0, part.length);
        return out.toByteArray();
    }

    private static byte[] tlv(int tag, byte[] value) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(tag);
        int length = value.length;
        if (length < 128) {
            out.write(length);
        } else if (length < 256) {
            out.write(0x81);
            out.write(length);
        } else if (length < 65536) {
            out.write(0x82);
            out.write(length >> 8);
            out.write(length);
        } else {
            out.write(0x83);
            out.write(length >> 16);
            out.write(length >> 8);
            out.write(length);
        }
        out.write(value, 0, value.length);
        return out.toByteArray();
    }
}
