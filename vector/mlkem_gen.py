"""FIPS 203 ML-KEM golden model and test-vector generator for mlkem_core.

The model is written directly from FIPS 203 (August 2024) and uses only
hashlib for SHA3/SHAKE. It is independent of the RTL: twiddles are derived
from zeta = 17, and the hardware-convention checks parse the NTT IP table only
to confirm the scaling assumptions the core relies on.

Usage:
    python3 mlkem_gen.py [N_RANDOM_PER_SET] [--seed S]
    python3 mlkem_gen.py clear
"""

import hashlib
import random
import re
import sys
from pathlib import Path

Q = 3329
N = 256
R = 1 << 16
QINV = 3327                      # -q^-1 mod 2^16

PARAMS = {
    0: dict(name="ML-KEM-512", k=2, eta1=3, eta2=2, du=10, dv=4),
    1: dict(name="ML-KEM-768", k=3, eta1=2, eta2=2, du=10, dv=4),
    2: dict(name="ML-KEM-1024", k=4, eta1=2, eta2=2, du=11, dv=5),
}

OP_KEYGEN, OP_ENCAPS, OP_DECAPS = 0, 1, 2
ERR_NONE, ERR_CFG, ERR_FRAME, ERR_KEY = 0, 1, 2, 3


def bitrev7(i):
    return int(f"{i:07b}"[::-1], 2)


ZETAS = [pow(17, bitrev7(i), Q) for i in range(128)]
GAMMAS = [pow(17, 2 * bitrev7(i) + 1, Q) for i in range(128)]


# ---------------------------------------------------------------- FIPS 203
def ntt(f):
    f = list(f)
    i = 1
    length = 128
    while length >= 2:
        for start in range(0, N, 2 * length):
            z = ZETAS[i]
            i += 1
            for j in range(start, start + length):
                t = z * f[j + length] % Q
                f[j + length] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        length //= 2
    return f


def intt(f):
    f = list(f)
    i = 127
    length = 2
    while length <= 128:
        for start in range(0, N, 2 * length):
            z = ZETAS[i]
            i -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (t + f[j + length]) % Q
                f[j + length] = z * (f[j + length] - t) % Q
        length *= 2
    return [x * 3303 % Q for x in f]


def multiply_ntts(a, b):
    h = [0] * N
    for i in range(128):
        a0, a1, b0, b1 = a[2 * i], a[2 * i + 1], b[2 * i], b[2 * i + 1]
        h[2 * i] = (a0 * b0 + a1 * b1 * GAMMAS[i]) % Q
        h[2 * i + 1] = (a0 * b1 + a1 * b0) % Q
    return h


def padd(a, b):
    return [(x + y) % Q for x, y in zip(a, b)]


def psub(a, b):
    return [(x - y) % Q for x, y in zip(a, b)]


def bytes_to_bits(b):
    return [(b[i // 8] >> (i % 8)) & 1 for i in range(8 * len(b))]


def byte_encode(f, d):
    bits = []
    for x in f:
        bits += [(x >> j) & 1 for j in range(d)]
    out = bytearray(len(bits) // 8)
    for i, v in enumerate(bits):
        out[i // 8] |= v << (i % 8)
    return bytes(out)


def byte_decode(b, d):
    bits = bytes_to_bits(b)
    m = Q if d == 12 else 1 << d
    return [sum(bits[i * d + j] << j for j in range(d)) % m for i in range(N)]


def compress(x, d):
    return ((x << d) + 1664) // Q % (1 << d)


def decompress(y, d):
    return (y * Q + (1 << (d - 1))) >> d


def H(s):
    return hashlib.sha3_256(s).digest()


def J(s):
    return hashlib.shake_256(s).digest(32)


def G(s):
    g = hashlib.sha3_512(s).digest()
    return g[:32], g[32:]


def prf(eta, s, b):
    return hashlib.shake_256(s + bytes([b])).digest(64 * eta)


def sample_ntt(seed34):
    n_bytes = 168 * 6
    stream = hashlib.shake_128(seed34).digest(n_bytes)
    a, pos = [], 0
    while len(a) < N:
        if pos + 3 > len(stream):
            n_bytes += 168
            stream = hashlib.shake_128(seed34).digest(n_bytes)
        c0, c1, c2 = stream[pos], stream[pos + 1], stream[pos + 2]
        pos += 3
        d1 = c0 + 256 * (c1 % 16)
        d2 = (c1 >> 4) + 16 * c2
        if d1 < Q:
            a.append(d1)
        if d2 < Q and len(a) < N:
            a.append(d2)
    return a, pos


def sample_cbd(b, eta):
    bits = bytes_to_bits(b)
    f = []
    for i in range(N):
        x = sum(bits[2 * i * eta + j] for j in range(eta))
        y = sum(bits[2 * i * eta + eta + j] for j in range(eta))
        f.append((x - y) % Q)
    return f


def kpke_keygen(d, p, trace=None):
    k, eta1 = p["k"], p["eta1"]
    rho, sigma = G(d + bytes([k]))
    a_hat = [[sample_ntt(rho + bytes([j, i]))[0] for j in range(k)] for i in range(k)]
    s = [sample_cbd(prf(eta1, sigma, i), eta1) for i in range(k)]
    e = [sample_cbd(prf(eta1, sigma, k + i), eta1) for i in range(k)]
    s_hat = [ntt(x) for x in s]
    e_hat = [ntt(x) for x in e]
    t_hat = []
    for i in range(k):
        acc = [0] * N
        for j in range(k):
            acc = padd(acc, multiply_ntts(a_hat[i][j], s_hat[j]))
        t_hat.append(padd(acc, e_hat[i]))
    ek = b"".join(byte_encode(x, 12) for x in t_hat) + rho
    dk = b"".join(byte_encode(x, 12) for x in s_hat)
    if trace is not None:
        trace.update(rho=rho, sigma=sigma, s_hat=s_hat, e_hat=e_hat, t_hat=t_hat)
    return ek, dk


def kpke_encrypt(ek, m, r, p, trace=None):
    k, eta1, eta2, du, dv = p["k"], p["eta1"], p["eta2"], p["du"], p["dv"]
    t_hat = [byte_decode(ek[384 * i:384 * (i + 1)], 12) for i in range(k)]
    rho = ek[384 * k:384 * k + 32]
    a_hat = [[sample_ntt(rho + bytes([j, i]))[0] for j in range(k)] for i in range(k)]
    y = [sample_cbd(prf(eta1, r, i), eta1) for i in range(k)]
    e1 = [sample_cbd(prf(eta2, r, k + i), eta2) for i in range(k)]
    e2 = sample_cbd(prf(eta2, r, 2 * k), eta2)
    y_hat = [ntt(x) for x in y]
    u = []
    for i in range(k):
        acc = [0] * N
        for j in range(k):
            acc = padd(acc, multiply_ntts(a_hat[j][i], y_hat[j]))
        u.append(padd(intt(acc), e1[i]))
    mu = [decompress(b, 1) for b in byte_decode(m, 1)]
    acc = [0] * N
    for j in range(k):
        acc = padd(acc, multiply_ntts(t_hat[j], y_hat[j]))
    v = padd(padd(intt(acc), e2), mu)
    c1 = b"".join(byte_encode([compress(x, du) for x in ui], du) for ui in u)
    c2 = byte_encode([compress(x, dv) for x in v], dv)
    if trace is not None:
        trace.update(y_hat=y_hat, u=u, v=v)
    return c1 + c2


def kpke_decrypt(dk_pke, c, p, trace=None):
    k, du, dv = p["k"], p["du"], p["dv"]
    u_p = [[decompress(x, du) for x in byte_decode(c[32 * du * i:32 * du * (i + 1)], du)]
           for i in range(k)]
    v_p = [decompress(x, dv) for x in byte_decode(c[32 * du * k:32 * (du * k + dv)], dv)]
    s_hat = [byte_decode(dk_pke[384 * i:384 * (i + 1)], 12) for i in range(k)]
    acc = [0] * N
    for j in range(k):
        acc = padd(acc, multiply_ntts(s_hat[j], ntt(u_p[j])))
    w = psub(v_p, intt(acc))
    m = byte_encode([compress(x, 1) for x in w], 1)
    if trace is not None:
        trace.update(w=w, m_prime=m)
    return m


def mlkem_keygen(d, z, p, trace=None):
    ek, dk_pke = kpke_keygen(d, p, trace)
    dk = dk_pke + ek + H(ek) + z
    return ek, dk


def mlkem_encaps(ek, m, p, trace=None):
    K, r = G(m + H(ek))
    c = kpke_encrypt(ek, m, r, p, trace)
    return K, c


def mlkem_decaps(dk, c, p, trace=None):
    k = p["k"]
    dk_pke = dk[:384 * k]
    ek = dk[384 * k:768 * k + 32]
    h = dk[768 * k + 32:768 * k + 64]
    z = dk[768 * k + 64:768 * k + 96]
    m_p = kpke_decrypt(dk_pke, c, p, trace)
    K_p, r_p = G(m_p + h)
    K_bar = J(z + c)
    c_p = kpke_encrypt(ek, m_p, r_p, p)
    if trace is not None:
        trace.update(match=(c == c_p), K_bar=K_bar, K_prime=K_p)
    return K_p if c == c_p else K_bar


def ek_is_valid(ek, p):
    k = p["k"]
    if len(ek) != 384 * k + 32:
        return False
    for i in range(k):
        seg = ek[384 * i:384 * (i + 1)]
        if byte_encode(byte_decode(seg, 12), 12) != seg:
            return False
    return True


def dk_is_valid(dk, p):
    k = p["k"]
    if len(dk) != 768 * k + 96:
        return False
    return H(dk[384 * k:768 * k + 32]) == dk[768 * k + 32:768 * k + 64]


# ------------------------------------------------- hardware convention checks
TWIDDLE_PATTERN = re.compile(
    r"7'd(\d+)\s*:\s*val\s*=\s*\{\s*(-?)\s*16'sd(\d+)\s*,\s*(-?)\s*16'sd(\d+)\s*\}\s*;"
)


def fqmul(a, b):
    return a * b * pow(R, -1, Q) % Q


def ntt_core_model(f, zetas_mont):
    r = list(f)
    k = 1
    length = 128
    while length >= 2:
        for start in range(0, N, 2 * length):
            z = zetas_mont[k]
            k += 1
            for j in range(start, start + length):
                t = fqmul(z, r[j + length])
                r[j + length] = (r[j] - t) % Q
                r[j] = (r[j] + t) % Q
        length >>= 1
    return r


def intt_core_model(f, zetas_inv_mont):
    r = list(f)
    k = 0
    length = 2
    while length <= 128:
        for start in range(0, N, 2 * length):
            z = zetas_inv_mont[k]
            k += 1
            for j in range(start, start + length):
                t = r[j]
                r[j] = (t + r[j + length]) % Q
                r[j + length] = fqmul(z, (t - r[j + length]) % Q)
        length <<= 1
    return [fqmul(x, zetas_inv_mont[127]) for x in r]


def check_hw_conventions(rng):
    """Confirm NTT-IP scaling (NTT exact, INTT x R) and arithmetic constants."""
    path = Path(__file__).resolve().parents[1] / "rtl/utils/ntt_funcs.vh"
    if path.exists():
        txt = path.read_text(errors="ignore")
        fwd, inv = [None] * 128, [None] * 128
        for m in TWIDDLE_PATTERN.finditer(txt):
            i = int(m.group(1))
            fwd[i] = (-1 if m.group(2) else 1) * int(m.group(3)) % Q
            inv[i] = (-1 if m.group(4) else 1) * int(m.group(5)) % Q
        for _ in range(4):
            a = [rng.randrange(Q) for _ in range(N)]
            assert ntt_core_model(a, fwd) == ntt(a), "NTT IP is not the exact FIPS NTT"
            assert intt_core_model(a, inv) == [x * R % Q for x in intt(a)], "INTT IP is not R*INTT"
        print("NTT IP convention: NTT exact, INTT scaled by R = 2^16 (checked)")
    else:
        print(f"NTT IP table not found at {path}; convention check skipped")

    for d, (mul, sh, bias) in COMPRESS_CONSTS.items():
        for x in range(Q):
            assert ((x * mul + bias) >> sh) % (1 << d) == compress(x, d), d
    for x in range(Q):
        assert montred(x * 1353) == x * R % Q
    print("Compress / MontRed constants verified exhaustively")


# Compress_d(x) = ((x * MUL + BIAS) >> SHIFT) mod 2^d, x in [0, q)
COMPRESS_CONSTS = {
    1: (315, 19, 1 << 18),
    4: (315, 16, 1 << 15),
    5: (315, 15, 1 << 14),
    10: (161271, 19, 262065),
    11: (161271, 18, 131032),
}


def montred(t):
    m = (t & 0xFFFF) * QINV & 0xFFFF
    u = (t + m * Q) >> 16
    return u - Q if u >= Q else u


def gamma_rom():
    """Basemul twiddles in the Montgomery form used by the PMAC lanes."""
    return [g * R % Q for g in GAMMAS]


# ------------------------------------------------------------ vector output
def words_of(b):
    assert len(b) % 8 == 0
    return [int.from_bytes(b[i:i + 8], "little") for i in range(0, len(b), 8)]


def seed_words(first32, second32=bytes(32)):
    return words_of(first32 + second32)


class Case:
    def __init__(self, name, op, pset, seed, inp, out, err=ERR_NONE):
        self.name, self.op, self.pset = name, op, pset
        self.seed, self.inp, self.out, self.err = seed, inp, out, err


def build_cases(n_random, rng):
    cases = []
    for pset, p in PARAMS.items():
        nm = p["name"]
        for it in range(n_random):
            d, z, m = (bytes(rng.randrange(256) for _ in range(32)) for _ in range(3))
            ek, dk = mlkem_keygen(d, z, p)
            K, c = mlkem_encaps(ek, m, p)
            assert mlkem_decaps(dk, c, p) == K, "key agreement failed"
            assert ek_is_valid(ek, p) and dk_is_valid(dk, p)
            tag = f"{nm}#{it}"
            cases.append(Case(f"{tag} KeyGen", OP_KEYGEN, pset, seed_words(d, z), b"", ek + dk))
            cases.append(Case(f"{tag} Encaps", OP_ENCAPS, pset, seed_words(m), ek, c + K))
            cases.append(Case(f"{tag} Decaps", OP_DECAPS, pset, seed_words(bytes(32)), dk + c, K))
            if it == 0:
                bad_c = bytearray(c)
                bad_c[rng.randrange(len(c))] ^= 1 << rng.randrange(8)
                bad_c = bytes(bad_c)
                k_bar = mlkem_decaps(dk, bad_c, p)
                assert k_bar == J(z + bad_c)
                cases.append(Case(f"{tag} Decaps implicit-reject", OP_DECAPS, pset,
                                  seed_words(bytes(32)), dk + bad_c, k_bar))

                bad_ek = bytearray(ek)
                pos = 3 * rng.randrange(128 * p["k"])          # 3-byte group of two coefficients
                bad_ek[pos] = 0xFF
                bad_ek[pos + 1] |= 0x0F                          # first coefficient >= q
                assert not ek_is_valid(bytes(bad_ek), p)
                cases.append(Case(f"{tag} Encaps invalid-ek", OP_ENCAPS, pset, seed_words(m),
                                  bytes(bad_ek), b"", ERR_KEY))

                bad_dk = bytearray(dk)
                bad_dk[768 * p["k"] + 40] ^= 0x5A
                assert not dk_is_valid(bytes(bad_dk), p)
                cases.append(Case(f"{tag} Decaps bad-H(ek)", OP_DECAPS, pset,
                                  seed_words(bytes(32)), bytes(bad_dk) + c, b"", ERR_KEY))
    return cases


def write_vectors(cases, out_dir):
    hdr, seeds, ins, outs = [], [], [], []
    for c in cases:
        nin, nout = len(c.inp) // 8, len(c.out) // 8
        hdr.append((c.op << 56) | (c.pset << 48) | (c.err << 40) | (nin << 20) | nout)
        seeds += c.seed
        ins += words_of(c.inp)
        outs += words_of(c.out)
    ins = ins or [0]
    outs = outs or [0]
    (out_dir / "tv_hdr.mem").write_text("".join(f"{w:016x}\n" for w in hdr))
    (out_dir / "tv_seed.mem").write_text("".join(f"{w:016x}\n" for w in seeds))
    (out_dir / "tv_in.mem").write_text("".join(f"{w:016x}\n" for w in ins))
    (out_dir / "tv_out.mem").write_text("".join(f"{w:016x}\n" for w in outs))
    lines = [f"cases {len(cases)} in_words {len(ins)} out_words {len(outs)}"]
    for i, c in enumerate(cases):
        lines.append(f"{i:3d} op={c.op} set={c.pset} err={c.err} in={len(c.inp)}B out={len(c.out)}B  {c.name}")
    (out_dir / "tv_spec.txt").write_text("\n".join(lines) + "\n")


def main():
    out_dir = Path(__file__).resolve().parent
    args = sys.argv[1:]
    if args and args[0] == "clear":
        for name in ("tv_hdr.mem", "tv_seed.mem", "tv_in.mem", "tv_out.mem", "tv_spec.txt"):
            (out_dir / name).unlink(missing_ok=True)
        print("Cleared vectors.")
        return 0
    seed = 2026
    if "--seed" in args:
        seed = int(args[args.index("--seed") + 1])
        del args[args.index("--seed"):args.index("--seed") + 2]
    n_random = int(args[0]) if args else 1
    rng = random.Random(seed)
    check_hw_conventions(rng)
    cases = build_cases(n_random, rng)
    write_vectors(cases, out_dir)
    print(f"Wrote {len(cases)} cases to {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
