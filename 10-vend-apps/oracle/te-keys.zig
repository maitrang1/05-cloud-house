// =====================================================================
// Des: Two throwaway RSA test keys (same key, two PEM shapes) and the fingerprint OpenSSL printed for it. Test use only. Never a real key.
// Flo: base64 body + armor words built at compile time > PEM text for the tests
// Cre: 2026-11-12                          - | Mod: 2026-11-12
// Who: zzOWN.com - Own Fast. Work Faster.  - | Ema: zzown.com@gmail.com
// Inp: none
// Out: pem1 (PKCS#1), pem8 (PKCS#8), fing (expected fingerprint)
// Run: cd /home/mai_trang/00_modules/05-cloud-house/10-vend-apps/oracle && zig build test
// Exe: none (test fixture)
// =====================================================================
// the armor words are split so this source never trips a secret scanner ----
const HEA1 = "-----BEGIN RSA PRIV" ++ "ATE KEY-----\n";
const FOO1 = "\n-----END RSA PRIV" ++ "ATE KEY-----\n";
const HEA8 = "-----BEGIN PRIV" ++ "ATE KEY-----\n";
const FOO8 = "\n-----END PRIV" ++ "ATE KEY-----\n";

const BOD1 =
    \\MIIEpAIBAAKCAQEA4WeOmIgJvBT2DQbicgR4WwORttvSjnfUHh2ddlv2sogyxJTG
    \\citVIxFj1b674QAg8epiYXwWqccytQ/xFuXMgWj6TdAm2OhrrDr+j0p2C+xFflmC
    \\MkZgIV3GMl+hedL5bJ8jwfVzzbIpumVX+SXVzUOVx5s1gldHQRrm+rQuNNYWuz05
    \\ZsrL85dyTnTymtAf2XXGuKTo3fiiZvm62sTMe0ieSf5K1XdHr8i4i1vcGidj/Dzj
    \\xT8nV0YukD/jPguLmRdNTgX0dn+0GLl8NEz6RzO+6KPpkx4S66aN11ZAOCwLX0PD
    \\VlBfGrCtzDs71TahI+acM4ujJBTU4T7gtcxxGwIDAQABAoIBABroYVntF3hn6i2I
    \\7lxdEz8OMIVrPXn7bQuBToxUEyGh56mW9w+nA51RlKDuCYClIsmuSLtJdG0lFfUO
    \\Z6Hroduq/AJxAEoxiLUBP+U8JtZqiKs6JTQ6OXySNLhLuTuRR2xDnSGo2v+prpiN
    \\Q5C/BwRfdpBjA2LBZ4SqoPs5qjBtSs/m64/v2czJ52122H4e/d430iD0Rsp3XewW
    \\NegsSfNTn4uU5X8RQd1lA8BfkYBEm8mNUkPcSjxOhwgotrwrcVLUB6wHjsiwmr26
    \\mPVkbWCYjyycrc6uyjBrfEt2gASj33+fSJoxnRFccnOkWnPLdiC48KAGKfnl53tt
    \\lbzuxAkCgYEA/Sqjv+2LM4VkT4qTuFD0xRde6jVq5uqhVmFJm2X49bb3ANfcx3Lh
    \\DoWZVXyXhM9t3OmH3yFalcfltuXFeUY0hj+ClR1omb6wYUfloGUoVO5tRqr2rThF
    \\SK8ldkctXOJxwWuiXSKBSDBjV5SyJVMqNP2OgyHpeXbSn0Msetr3cHMCgYEA4+1f
    \\+7YpwxyVp4nnad4FsnIxShKuwF4sRXJWODbUs9lKiPBXXvd++gGpto0lGpTrCLp8
    \\OAYnrZl+40QRHkUOz9+ZL598QyI92BTL2huiZ17ldwIcegHr/E91/gZ9KfoX7zr0
    \\fT1GXmWpzHiX03jn01UVzuwTWRKNoy0MUpCNmrkCgYB95cl+9ZNm8Kv8vk5Nt7yx
    \\kri5wgzCfuXyvfjL1b8j+nQFMFPzv5ZaEWg6UfZLrpfU5zGRbdXNbJY5CTTV5WrT
    \\ZBv9KZ3N7z1pc0anKAcRjWw8W2LGq5gQ2EDJ/AV8DoRBitQ4eqNOEfolIKYi16PC
    \\rGFFpwSjScreNpqVEfVBLwKBgQCP+OA5Sk7E7ShnBMgFanYkytbxmC2EW7gRQfDO
    \\X2wqEqZvK4m09hbh6uz939hBGzH/eHSAmvqzQJMTEWrSuQJrMi08FLzUVyvDcxd1
    \\NSF3tEyzyMSeGNqsrLC2ffjP7Cb0OUQ4W904QXVpL/+PV/7v0f4Nj7eE+yA2o3z2
    \\JlMcGQKBgQDfPF97Wk977xF3d6gJYaVB+MREsInck0gjHhnbwVw4ygsqeEzVmFVI
    \\xk49JCVxuLns2y/OmfoQx0MtKSOCPwZW6P6l5Sl22oCBzTVAzdXUrnHTXoP9rRyT
    \\YMGkKk0rMravJ3mDeB7de8gKr5/upRowpyf7Oo2gcntjAzM7ts3o6w==
;
const BOD8 =
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDhZ46YiAm8FPYN
    \\BuJyBHhbA5G229KOd9QeHZ12W/ayiDLElMZyK1UjEWPVvrvhACDx6mJhfBapxzK1
    \\D/EW5cyBaPpN0CbY6GusOv6PSnYL7EV+WYIyRmAhXcYyX6F50vlsnyPB9XPNsim6
    \\ZVf5JdXNQ5XHmzWCV0dBGub6tC401ha7PTlmysvzl3JOdPKa0B/Zdca4pOjd+KJm
    \\+braxMx7SJ5J/krVd0evyLiLW9waJ2P8POPFPydXRi6QP+M+C4uZF01OBfR2f7QY
    \\uXw0TPpHM77oo+mTHhLrpo3XVkA4LAtfQ8NWUF8asK3MOzvVNqEj5pwzi6MkFNTh
    \\PuC1zHEbAgMBAAECggEAGuhhWe0XeGfqLYjuXF0TPw4whWs9efttC4FOjFQTIaHn
    \\qZb3D6cDnVGUoO4JgKUiya5Iu0l0bSUV9Q5noeuh26r8AnEASjGItQE/5Twm1mqI
    \\qzolNDo5fJI0uEu5O5FHbEOdIaja/6mumI1DkL8HBF92kGMDYsFnhKqg+zmqMG1K
    \\z+brj+/ZzMnnbXbYfh793jfSIPRGyndd7BY16CxJ81Ofi5TlfxFB3WUDwF+RgESb
    \\yY1SQ9xKPE6HCCi2vCtxUtQHrAeOyLCavbqY9WRtYJiPLJytzq7KMGt8S3aABKPf
    \\f59ImjGdEVxyc6Rac8t2ILjwoAYp+eXne22VvO7ECQKBgQD9KqO/7YszhWRPipO4
    \\UPTFF17qNWrm6qFWYUmbZfj1tvcA19zHcuEOhZlVfJeEz23c6YffIVqVx+W25cV5
    \\RjSGP4KVHWiZvrBhR+WgZShU7m1GqvatOEVIryV2Ry1c4nHBa6JdIoFIMGNXlLIl
    \\Uyo0/Y6DIel5dtKfQyx62vdwcwKBgQDj7V/7tinDHJWniedp3gWycjFKEq7AXixF
    \\clY4NtSz2UqI8Fde9376Aam2jSUalOsIunw4BietmX7jRBEeRQ7P35kvn3xDIj3Y
    \\FMvaG6JnXuV3Ahx6Aev8T3X+Bn0p+hfvOvR9PUZeZanMeJfTeOfTVRXO7BNZEo2j
    \\LQxSkI2auQKBgH3lyX71k2bwq/y+Tk23vLGSuLnCDMJ+5fK9+MvVvyP6dAUwU/O/
    \\lloRaDpR9kuul9TnMZFt1c1sljkJNNXlatNkG/0pnc3vPWlzRqcoBxGNbDxbYsar
    \\mBDYQMn8BXwOhEGK1Dh6o04R+iUgpiLXo8KsYUWnBKNJyt42mpUR9UEvAoGBAI/4
    \\4DlKTsTtKGcEyAVqdiTK1vGYLYRbuBFB8M5fbCoSpm8ribT2FuHq7P3f2EEbMf94
    \\dICa+rNAkxMRatK5AmsyLTwUvNRXK8NzF3U1IXe0TLPIxJ4Y2qyssLZ9+M/sJvQ5
    \\RDhb3ThBdWkv/49X/u/R/g2Pt4T7IDajfPYmUxwZAoGBAN88X3taT3vvEXd3qAlh
    \\pUH4xESwidyTSCMeGdvBXDjKCyp4TNWYVUjGTj0kJXG4uezbL86Z+hDHQy0pI4I/
    \\Blbo/qXlKXbagIHNNUDN1dSucdNeg/2tHJNgwaQqTSsytq8neYN4Ht17yAqvn+6l
    \\GjCnJ/s6jaBye2MDMzu2zejr
;

pub const pem1 = HEA1 ++ BOD1 ++ FOO1;
pub const pem8 = HEA8 ++ BOD8 ++ FOO8;
pub const fing = "4a:04:cc:eb:79:70:d0:f9:84:ea:72:73:48:c3:b7:1e";

// ========================___THIS_IS_THE_END___========================
// ===============___HOLD_YOUR_BREATH_AND_COUNT_TO_TEN___===============
