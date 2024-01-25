import requests
from datetime import datetime

import subprocess

# Function to read cookie from a file
def read_cookie_from_file(file_path):
    with open(file_path, 'r') as file:
        return file.read().strip()

# Get the cookie from cookies.txt
cookie = read_cookie_from_file("cookies.txt")

# Get the current date and format it as [MONTH][DAY][2-digit-year]
current_date = datetime.now()
formatted_date = current_date.strftime("%b%d%y")

# Construct the URL with the formatted date
url = f"https://www.nytimes.com/svc/crosswords/v2/puzzle/print/{formatted_date}.pdf"

headers = {
    'Referer': 'https://www.nytimes.com/crosswords/archive/daily',
    'Cookie': cookie
}

response = requests.get(url, headers=headers, stream=True)

if response.status_code == 200:
    with open(f"xwords/{formatted_date}.pdf", 'wb') as f:
        f.write(response.content)

        subprocess.run(["rmapi", "put", f"xwords/{formatted_date}.pdf", "/art/xword"])

else:
    print("Failed to download the file. Status code:", response.status_code)
