import requests
import time
import random

urls = ['/', '/login', '/admin']
while True:
    url = random.choice(urls)
    try:
        requests.get(f"http://192.168.56.10{url}", timeout=2)
    except:
        pass
    time.sleep(0.1)
