from imapclient import IMAPClient
mail = IMAPClient('imap.gmail.com', ssl=True, port=993)
#Password of email need to generated for device as gmail stoped unscure login process explained on read me
mail.login("your@email.com", "yourgeneratedpassword")
totalMail = mail.select_folder('Inbox')
#Shows how many messages are there - both read and unread
print('You have total %d emails in your folder' % totalMail[b'EXISTS'])
delMsg = mail.search(('UNSEEN'))
mail.delete_messages(delMsg)
#Shows number of unread messages that have been archived now
print('%d unread emails in your folder have been archived' % len(delMsg))
mail.logout()