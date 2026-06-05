#!/usr/bin/env python3
# dev@cizion.com 받은편지함에서 새(UNSEEN) CloudWatch ALARM 메일을 찾아
# 알람 이름을 한 줄씩 출력하고 읽음 처리한다. (읽기+읽음플래그만, 삭제 안 함)
import imaplib, email, os, re, sys
from email.header import decode_header, make_header

host = os.environ.get("IMAP_HOST", "imap.gmail.com")
user = os.environ.get("EMAIL_USER", "")
pw   = os.environ.get("EMAIL_APP_PASSWORD", "")
if not (user and pw):
    sys.exit(0)

try:
    m = imaplib.IMAP4_SSL(host)
    m.login(user, pw)
    m.select("INBOX")
    # CloudWatch 알람 메일: 제목이 ALARM: "..." 로 시작
    typ, data = m.search(None, '(UNSEEN SUBJECT "ALARM:")')
    for num in (data[0].split() if data and data[0] else []):
        typ, d = m.fetch(num, "(RFC822)")
        if not d or not d[0]:
            continue
        msg = email.message_from_bytes(d[0][1])
        subj = str(make_header(decode_header(msg.get("Subject", ""))))
        mt = re.search(r'ALARM:\s*"([^"]+)"', subj)
        if mt:
            print(mt.group(1))
        m.store(num, "+FLAGS", "\\Seen")
    m.logout()
except Exception as e:
    sys.stderr.write(f"email_fetch error: {e}\n")
    sys.exit(0)
