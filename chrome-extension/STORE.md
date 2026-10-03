# Publishing to the Chrome Web Store

One-time, owner-side (needs the Google account that will own the listing).
After this, installing the extension is one click from Settings, and pairing
is automatic.

## 1. Build the upload

Every release already attaches `chrome-extension-<version>.zip` (see the
GitHub release page). Or build one by hand:

```sh
cd chrome-extension && zip -r ../build/chrome-extension.zip . -x 'test/*' '.*'
```

## 2. Register and upload

1. https://chrome.google.com/webstore/devconsole → sign in → pay the one-time
   $5 developer registration.
2. **New item** → upload the zip.

## 3. Listing

- **Name:** Look Ma, No Hands
- **Summary:** Lets the Look Ma, No Hands assistant see and act on the exact elements of a page.
- **Description:**

  > The browser hand for Look Ma, No Hands. With it installed, the assistant on your Mac reads the page you're working on as a numbered map of its real elements — every link, button, field and result — and clicks or types by that exact element instead of guessing from a screenshot.
  >
  > It only ever talks to the Look Ma, No Hands app on your own computer, over a local connection. No servers, no analytics, nothing stored beyond the pairing code. A page is read only while the assistant is carrying out something you asked for.
  >
  > Requires the Look Ma, No Hands desktop app (nohandsapp.com).

- **Category:** Productivity
- **Language:** English
- **Icon:** `icons/128.png`
- **Screenshots (1280×800):** the app's Settings › Chrome extension section; a page with the assistant's activity log showing a "chrome: clicked e12" line; the setup page showing "Connected".
- **Homepage:** https://nohandsapp.com/chrome-extension
- **Privacy policy:** https://nohandsapp.com/chrome-extension/privacy
- **Support:** hello@nohandsapp.com

## 4. Privacy practices tab (answers)

- **Single purpose:** Let the Look Ma, No Hands desktop app read and act on the current web page's elements on the user's request.
- **Permission justifications:**
  - `host_permissions <all_urls>`: reads whichever page the user asks the app to act on; only on request.
  - `tabs`: lists and switches tabs by title.
  - `scripting`: injects the page reader to list elements and perform the requested click/typing.
  - `storage`: stores the pairing code and port.
  - `alarms`: keeps the local connection to the desktop app alive.
- **Remote code:** No.
- **Data usage:** Website content is read and sent only to a local application on the user's device; not sold, not used for unrelated purposes, not for creditworthiness or lending.

## 5. After it's live

Set the listing URL on Vercel so the app and website point at it:

```
NEXT_PUBLIC_CHROME_WEBSTORE_URL=https://chromewebstore.google.com/detail/<id>
```

Settings › Chrome extension › **Install Chrome extension** opens
`nohandsapp.com/chrome-extension#code=<pairing code>`: Add to Chrome, and the
extension pairs itself from the code in the URL fragment (never sent to the
server). Updates then arrive through the store automatically.
