"""Extract explicit localization keys without executing Swift or touching user data.

The lexer handles comments, nested interpolation, raw strings and multiline
literals. It does not rewrite Swift. Internal display-enum keys are tracked in
an explicit supplement so identifiers and document text never become keys.
"""
from __future__ import annotations
from dataclasses import dataclass
from pathlib import Path
import re
import textwrap

@dataclass
class Literal:
    start: int
    end: int
    key: str
    interpolation_count: int

ESCAPES = {'n':'\n','r':'\r','t':'\t','0':'\0','\\':'\\','"':'"',"'":"'"}

def comment_end(source: str, start: int) -> int:
    if source.startswith('//',start):
        end=source.find('\n',start)
        return len(source) if end<0 else end
    depth=1; cursor=start+2
    while cursor<len(source) and depth:
        if source.startswith('/*',cursor): depth+=1; cursor+=2
        elif source.startswith('*/',cursor): depth-=1; cursor+=2
        else: cursor+=1
    return cursor

def literal_start(source: str, start: int) -> tuple[int,int] | None:
    cursor=start
    while cursor<len(source) and source[cursor]=='#': cursor+=1
    if cursor>=len(source) or source[cursor]!='"': return None
    return cursor-start, 3 if source.startswith('"""',cursor) else 1

def read_literal(source: str, start: int, nested: list[Literal]) -> Literal:
    beginning=literal_start(source,start)
    assert beginning is not None
    hashes,quotes=beginning
    opening=hashes+quotes
    terminator='"'*quotes+'#'*hashes
    escape='\\'+'#'*hashes
    cursor=start+opening
    parts=[]; count=0
    while cursor<len(source):
        if source.startswith(terminator,cursor):
            end=cursor+len(terminator)
            key=''.join(parts)
            if quotes==3:
                # Swift removes the opening newline and the closing delimiter's
                # indentation from every nonempty line.
                if key.startswith('\r\n'): key=key[2:]
                elif key.startswith('\n'): key=key[1:]
                closing_line=source[source.rfind('\n',start,cursor)+1:cursor]
                if not closing_line.strip():
                    indent=closing_line
                    lines=key.splitlines(keepends=True)
                    key=''.join(line[len(indent):] if line.startswith(indent) else line for line in lines)
                    if key.endswith('\r\n'): key=key[:-2]
                    elif key.endswith('\n'): key=key[:-1]
            return Literal(start,end,key,count)
        if source.startswith(escape,cursor):
            after=cursor+len(escape)
            if after<len(source) and source[after]=='(':
                parts.append('{'+str(count)+'}'); count+=1
                depth=1; cursor=after+1
                while cursor<len(source) and depth:
                    if source.startswith('//',cursor) or source.startswith('/*',cursor): cursor=comment_end(source,cursor)
                    elif literal_start(source,cursor):
                        child=read_literal(source,cursor,nested)
                        nested.append(child); cursor=child.end
                    elif source[cursor]=='(': depth+=1; cursor+=1
                    elif source[cursor]==')': depth-=1; cursor+=1
                    else: cursor+=1
                continue
            if after<len(source) and source[after]=='u' and source.startswith('{',after+1):
                end=source.find('}',after+2)
                if end>=0:
                    parts.append(chr(int(source[after+2:end],16))); cursor=end+1; continue
            if after<len(source) and source[after] in ESCAPES:
                parts.append(ESCAPES[source[after]]); cursor=after+1; continue
            if after<len(source) and source[after] in '\r\n':
                cursor=after+1
                if source[after]=='\r' and cursor<len(source) and source[cursor]=='\n': cursor+=1
                while cursor<len(source) and source[cursor] in ' \t': cursor+=1
                continue
        parts.append(source[cursor]); cursor+=1
    raise ValueError('Unterminated Swift literal at offset '+str(start))

def literals(source: str) -> list[Literal]:
    result=[]; cursor=0
    while cursor<len(source):
        if source.startswith('//',cursor) or source.startswith('/*',cursor): cursor=comment_end(source,cursor)
        elif literal_start(source,cursor):
            token=read_literal(source,cursor,result)
            result.append(token); cursor=token.end
        else: cursor+=1
    return sorted(result,key=lambda item:item.start)

def explicit_keys(root: Path) -> dict[str,list[str]]:
    result: dict[str,list[str]]={}
    for file in sorted((root/'Sources/CartaPDF').glob('*.swift')):
        source=file.read_text()
        for token in literals(source):
            if re.search(r'L10n\.(?:tr|string)\s*\(\s*$',source[max(0,token.start-100):token.start]):
                location=f'{file.relative_to(root)}:{source.count(chr(10),0,token.start)+1}'
                result.setdefault(token.key,[]).append(location)
    return result
