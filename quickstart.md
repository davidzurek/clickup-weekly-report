# ClickUp Automated Weekly Report

Automatically fetches tasks and comments from ClickUp, generates a structured weekly progress report using an LLM Model (Claude or GPT), and pushes it as a new page to a ClickUp Doc.

## How it works
1. Fetches all lists from a given ClickUp folder
2. Fetches tasks updated within the lookback window (filtered by assignee and status)
3. Fetches comments and threaded replies for each task
4. Merges everything into a single `merged.json`
5. Sends the data to Claude (`claude-sonnet-4-6`) or OpenAI to generate a markdown report
6. Pushes the report as a new page to a ClickUp Doc

## Prerequisites
1. Email address that is [linked to a Google Account](https://support.google.com/accounts/answer/176347?hl=en&co=GENIE.Platform%3DDesktop&oco=0#)
2. Browser, where you are logged in with your Google Account
3. ClickUp Info:
    1. User-ID
    2. Doc-ID
    3. Parent-Page-ID
    4. ClickUp API Key
4. LLM API Key (currently works only with Anthropic Claude & OpenAI)

## **Finding your IDs and API keys**
### ClickUp IDs
#### User-ID
*   In the sidebar, click `Teams`
*   Search for your username
*   Hover over your user box → click the three dots (top-right corner)
*   Copy your `Member ID`
    ![](https://t2634247.p.clickup-attachments.com/t2634247/9b79e9ea-b2f9-4682-b855-6f365ed96b59/Screenshot%202026-04-14%20at%2010.38.37.png)

#### Doc-ID & Parent-ID
* In the sidebar, click `Home` > `DGP Team` > `DGP - Admin` > `{your-name}` > `{current-year}`
*   In the url bar you can see the doc-id and the parent-page-id after `v/doc/`
*   The doc id is the part right after `/doc/`
*   The parent-page id is the part after the slash `/` of the doc id
    ![](https://t2634247.p.clickup-attachments.com/t2634247/bf9e5499-f292-4177-86b2-33630d61f96b/Screenshot%202026-04-14%20at%2010.42.04.png)

#### ClickUp API Token
* Top-right corner > click your avatar > `Settings`
* Under `All Settings` , click `ClickUp API`
* Generate a new personal API token and store it somewhere safe
    ![](https://t2634247.p.clickup-attachments.com/t2634247/62ecd374-0d1d-41a4-b538-ba576dfafc99/Screenshot%202026-04-14%20at%2010.54.04.png)

### LLM API Key
#### Anthropic Claude
* Go to [platform.claude.com](http://platform.claude.com)
* Bottom-right corner > `Settings`
* Navigate to `API Keys`
* Create a new key and store it somewhere safe
* **NOTE: Make sure you have Free-Credits OR a billing plan set up. Otherwise your API requests to Claude will not succeed. Check it under [billing settings](https://platform.claude.com/settings/billing)**

    ![](https://t2634247.p.clickup-attachments.com/t2634247/332776cc-ad71-4143-9e68-beef687d04dd/Screenshot%202026-04-14%20at%2011.01.06.png)

#### Open AI
* Similar approach to Anthropic
* Visit [openai website](https://platform.openai.com/api-keys) and get your token there

## Browser-based deployment option
* With your logged in Google Account in your browser, open this url: [https://europe-west3-crfe-sbox-int.cloudfunctions.net/provision-user](https://europe-west3-crfe-sbox-int.cloudfunctions.net/provision-user)
* Fill out the form with the required fields

![](https://t2634247.p.clickup-attachments.com/t2634247/d01874d8-cded-4b83-ab41-7966db786043/Screenshot%202026-04-14%20at%2011.07.15.png)

* For the `Provisioning Key` copy [this value](https://console.cloud.google.com/security/secret-manager/secret/cu-provisioning-key/versions?project=crfe-sbox-int) into the dedicated form field
![](https://t2634247.p.clickup-attachments.com/t2634247/96f90d8d-0c71-41b6-94af-3be802ab78a8/Screenshot%202026-04-14%20at%2011.11.28.png)
* Wait 2-3 min until you get a green success message
* Double check your ClickUp report - make sure all information are correct