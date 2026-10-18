#!/usr/bin/env python3
"""Write an original, deterministic PDF for interface snapshots (standard library only)."""
import argparse
import hashlib
from pathlib import Path


def fixture_bytes():
    objects = {
        1: b'<< /Type /Catalog /Pages 2 0 R /Outlines 13 0 R /AcroForm << /Fields [8 0 R 9 0 R] /DA (/F1 12 Tf 0 g) /DR << /Font << /F1 6 0 R >> >> >> >>',
        2: b'<< /Type /Pages /Count 3 /Kids [3 0 R 4 0 R 5 0 R] >>',
        6: b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
        8: b'<< /Type /Annot /Subtype /Widget /FT /Tx /T (Synthetic long form field name for multilingual interface layout) /V (UI Audit value 123) /Rect [40 430 330 462] /P 3 0 R /F 4 /DA (/F1 12 Tf 0 g) >>',
        9: b'<< /Type /Annot /Subtype /Widget /FT /Btn /T (Synthetic checkbox) /V /Off /AS /Off /Rect [40 380 60 400] /P 3 0 R /F 4 /AP << /N << /Off 15 0 R /Yes 16 0 R >> >> >>',
        10: b'<< /Type /Annot /Subtype /Text /Rect [420 640 450 670] /Contents (Synthetic annotation for UI audit) /T (UI Audit) /F 4 >>',
        13: b'<< /Type /Outlines /First 14 0 R /Last 14 0 R /Count 1 >>',
        14: b'<< /Title (Synthetic long bookmark: English Italiano Espanol Deutsch Francais) /Parent 13 0 R /Dest [3 0 R /Fit] >>',
    }
    for page, page_object, content_object in [(1, 3, 7), (2, 4, 11), (3, 5, 12)]:
        annotations = b' /Annots [8 0 R 9 0 R 10 0 R]' if page == 1 else b''
        objects[page_object] = (
            b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 6 0 R >> >> /Contents '
            + str(content_object).encode() + b' 0 R' + annotations + b' >>')
        content = (f'BT /F1 22 Tf 40 760 Td (CartaPDF UI audit - page {page}) Tj /F1 14 Tf 0 -45 Td '
                   '(Synthetic document, no personal data.) Tj 0 -35 Td '
                   '(English Italiano Espanol Deutsch Francais Chinese Japanese) Tj ET\n').encode()
        objects[content_object] = (f'<< /Length {len(content)}  >>\nstream\n'.encode()
                                   + content + b'endstream')
    for number, content in [(15, b'0.5 w 1 1 18 18 re S\n'),
                            (16, b'0.5 w 1 1 18 18 re S 2 w 4 10 m 8 4 l 17 17 l S\n')]:
        objects[number] = (f'<< /Length {len(content)} /Type /XObject /Subtype /Form /BBox [0 0 20 20] /Resources << >> >>\nstream\n'.encode()
                           + content + b'endstream')
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = {}
    for number in sorted(objects):
        offsets[number] = len(data)
        data += f'{number} 0 obj\n'.encode() + objects[number] + b'\nendobj\n'
    start = len(data)
    data += b'xref\n0 17\n0000000000 65535 f \n'
    for number in range(1, 17):
        data += f'{offsets[number]:010d} 00000 n \n'.encode()
    data += (f'trailer\n<< /Root 1 0 R /Size 17 /ID [<1234><5678>] >>\n'
             f'startxref\n{start}\n%%EOF\n').encode()
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path, help='New PDF file; existing files are never overwritten')
    arguments = parser.parse_args()
    data = fixture_bytes()
    with arguments.output.open('xb') as stream:
        stream.write(data)
    print(f'Created synthetic UI fixture: {len(data)} bytes, SHA-256 {hashlib.sha256(data).hexdigest()}')


if __name__ == '__main__':
    main()
