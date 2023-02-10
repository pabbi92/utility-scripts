# What this script do?
- this script simply read your gmail account and delete all unseen email 

# How to setup and run

- brew install python3
- brew install python3-pip
- pip3 install IMAPClient
- setup Enable IMAP in your gmail account: Login to gmail > settings > Forwarding and POP/IMAP > Enable IMAP
- Use 16 digit code provided by google instead of password and that will serve as authentication token.follow this [thread](https://stackoverflow.com/questions/72480275/is-there-a-work-around-google-disabling-less-secure-apps#:~:text=please%20enable%202%2Dfactor%20authentication%20in%20google%20account%20before%20proceeding)
- replace your email at place <"your@email.com"> and generated password at place <"yourgeneratedpassword"> in script
- phython3 <your-system-path>/utility-scripts/python/email/delete-bulk-emails/archUnseenMail.py