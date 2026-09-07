#!/usr/bin/env python3
"""pngio.py - the few image operations the Stagehand companions need, with Pillow when it is installed and a
small pure-Python PNG path otherwise (8-bit RGB / RGBA / grey, non-interlaced: what scrot, import, screencapture
and .NET write). Pillow is faster and handles every PNG; install it with `pip install pillow` for big sessions.

    im = load(path)            -> Image (Pillow) or Raw (pure Python)
    size(im) -> (w, h); crop(im, x0, y0, x1, y1); paste(dst, src, x, y); new(w, h, rgb); fill(im, x0, y0, x1, y1, rgb)
    resize(im, w, h)           -> box filter (pure Python: integer factors only)
    pixel(im, x, y) -> (r, g, b); save(im, path)
"""
import struct
import zlib

try:
    from PIL import Image
    HAVE_PIL = True
except ImportError:   # pragma: no cover - the fallback path
    Image = None
    HAVE_PIL = False


class Raw:
    """RGB image as one bytearray, 3 bytes per pixel, row-major."""

    def __init__(self, w, h, data=None):
        self.w, self.h = w, h
        self.data = data if data is not None else bytearray(w * h * 3)

    @property
    def size(self):
        return self.w, self.h


# --- pure-Python PNG --------------------------------------------------------------------------------------------

def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def _unfilter(rows, bpp, stride):
    out = []
    prev = bytearray(stride)
    for ftype, line in rows:
        cur = bytearray(line)
        if ftype == 1:
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 255
        elif ftype == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 255
        elif ftype == 3:
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 255
        elif ftype == 4:
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + _paeth(a, prev[i], c)) & 255
        elif ftype != 0:
            raise ValueError('unknown PNG filter %d' % ftype)
        out.append(cur)
        prev = cur
    return out


def png_read(path):
    with open(path, 'rb') as f:
        data = f.read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('%s is not a PNG file' % path)
    pos, w, h, depth, ctype, interlace, idat = 8, 0, 0, 0, 0, 0, []
    while pos < len(data):
        length, tag = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif tag == b'IDAT':
            idat.append(body)
        elif tag == b'IEND':
            break
    if depth != 8 or interlace != 0 or ctype not in (0, 2, 6, 4):
        raise ValueError('%s: %d-bit colour type %d%s is not handled without Pillow (pip install pillow)' % (path, depth, ctype, ' interlaced' if interlace else ''))
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    stride = w * channels
    raw = zlib.decompress(b''.join(idat))
    rows = []
    for y in range(h):
        off = y * (stride + 1)
        rows.append((raw[off], raw[off + 1:off + 1 + stride]))
    lines = _unfilter(rows, channels, stride)
    img = Raw(w, h)
    d = img.data
    for y, line in enumerate(lines):
        o = y * w * 3
        if channels == 3:
            d[o:o + w * 3] = line
        elif channels == 4:
            d[o:o + w * 3:3] = line[0::4]
            d[o + 1:o + w * 3:3] = line[1::4]
            d[o + 2:o + w * 3:3] = line[2::4]
        elif channels == 1:
            d[o:o + w * 3:3] = line
            d[o + 1:o + w * 3:3] = line
            d[o + 2:o + w * 3:3] = line
        else:
            d[o:o + w * 3:3] = line[0::2]
            d[o + 1:o + w * 3:3] = line[0::2]
            d[o + 2:o + w * 3:3] = line[0::2]
    return img


def png_write(img, path):
    w, h, d = img.w, img.h, img.data
    rows = b''.join(b'\x00' + bytes(d[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(tag, body):
        return struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(rows, 6)))
        f.write(chunk(b'IEND', b''))


# --- the common operations -----------------------------------------------------------------------------------------

def load(path):
    if HAVE_PIL:
        return Image.open(path).convert('RGB')
    return png_read(path)


def save(im, path):
    if HAVE_PIL:
        im.save(path, optimize=True)
    else:
        png_write(im, path)


def size(im):
    return im.size


def new(w, h, rgb=(40, 40, 40)):
    if HAVE_PIL:
        return Image.new('RGB', (w, h), rgb)
    img = Raw(w, h)
    img.data[:] = bytes(rgb) * (w * h)
    return img


def crop(im, x0, y0, x1, y1):
    if HAVE_PIL:
        return im.crop((x0, y0, x1, y1))
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(im.w, x1), min(im.h, y1)
    w, h = max(0, x1 - x0), max(0, y1 - y0)
    out = Raw(w, h)
    for y in range(h):
        so = ((y0 + y) * im.w + x0) * 3
        out.data[y * w * 3:(y + 1) * w * 3] = im.data[so:so + w * 3]
    return out


def paste(dst, src, x, y):
    if HAVE_PIL:
        dst.paste(src, (x, y))
        return
    for sy in range(src.h):
        dy = y + sy
        if dy < 0 or dy >= dst.h:
            continue
        sx0, dx0 = 0, x
        if dx0 < 0:
            sx0, dx0 = -dx0, 0
        n = min(src.w - sx0, dst.w - dx0)
        if n <= 0:
            continue
        dst.data[(dy * dst.w + dx0) * 3:(dy * dst.w + dx0 + n) * 3] = src.data[(sy * src.w + sx0) * 3:(sy * src.w + sx0 + n) * 3]


def fill(im, x0, y0, x1, y1, rgb):
    if HAVE_PIL:
        from PIL import ImageDraw
        ImageDraw.Draw(im).rectangle((x0, y0, x1 - 1, y1 - 1), fill=rgb)
        return
    row = bytes(rgb) * max(0, x1 - x0)
    for y in range(max(0, y0), min(im.h, y1)):
        im.data[(y * im.w + x0) * 3:(y * im.w + x1) * 3] = row


def pixel(im, x, y):
    if HAVE_PIL:
        return im.getpixel((x, y))[:3]
    o = (y * im.w + x) * 3
    return tuple(im.data[o:o + 3])


def resize(im, w, h):
    if HAVE_PIL:
        return im.resize((w, h), Image.LANCZOS)
    fx, fy = im.w / w, im.h / h
    if abs(fx - round(fx)) > 1e-6 or abs(fy - round(fy)) > 1e-6 or fx < 1 or fy < 1:
        raise ValueError('resize by a non-integer factor needs Pillow (pip install pillow)')
    fx, fy = int(round(fx)), int(round(fy))
    out = Raw(w, h)
    n = fx * fy
    src = im.data
    for y in range(h):
        for x in range(w):
            r = g = b = 0
            for dy in range(fy):
                o = ((y * fy + dy) * im.w + x * fx) * 3
                for dx in range(fx):
                    r += src[o]
                    g += src[o + 1]
                    b += src[o + 2]
                    o += 3
            oo = (y * w + x) * 3
            out.data[oo] = r // n
            out.data[oo + 1] = g // n
            out.data[oo + 2] = b // n
    return out


def mean_luma(im):
    """Average brightness 0..255 of an image (flash detection on frame sequences)."""
    if HAVE_PIL:
        from PIL import ImageStat
        return ImageStat.Stat(im.convert('L')).mean[0]
    d = im.data
    n = im.w * im.h
    if n == 0:
        return 0.0
    return (sum(d[0::3]) * 299 + sum(d[1::3]) * 587 + sum(d[2::3]) * 114) / (1000.0 * n)
