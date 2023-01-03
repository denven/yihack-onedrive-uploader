# OneDrive-uploader for Yi IP Cameras
 This repository is inspired by [roleoroleo](https://github.com/roleoroleo)'s [yi-hack-MStar.gdrive uploader](https://github.com/roleoroleo/yi-hack-MStar.gdrive). However, my Google drive has only 15GB space shared with Gmail and other account applications, and it is very easy to get the whole storage fully packed with media files uploaded. Fortunately, I've subscribed Microsoft 365 Developer Program which provides 5TB storage space. I think uploading files to OneDrive is a better option for me.
>
> If you have a subscription of Microsoft OneDrive Stroage or Microsoft 365 Developer Program, you will get more storage space, which can allow you to store your camera videos and pictures to it other than paying an expensive manufacturer's storage premium plan.

## Features
- much easier to set up
  - use a JSON file as the configuration file
  - only few steps on your camera terminal
- unattended upload your video (.mp4) and image (.jpg) files once set up

## Supported camera models
> Yi cameras hacked with the same file hiearacy or builtin applications is more likely to be supported. Anyway, tests are required before you use it. I've tested on my own camera.
  - [x] model y201c(Yi 1080p Dome BFUS) with firmware 4.6.0.0A_201908271549 and yi-hack-MStar 0.4.7 by [denven](https://github.com/denven)
  - [ ] welcome to test it on your camera :smile:

## How to use the uploader?
### Prerequisites
1. make sure you've hacked your camera, please check [yi-hack-MStar)](https://github.com/roleoroleo/yi-hack-MStar)
2. you have an OneDrive account assosiated with your [Microsoft Azure](https://portal.azure.com/) account, you'd better have some knowledge of using Azure portal.


## Create Azure application for your uploader
1. register a **`Web`** type application on [Azure portal](https://portal.azure.com/)
2. set a **Redirect URI** for your application
![Set up callback URL](./screenshots/redirect_url.png)
> For this step, you can clone [OAuth2 callback](https://github.com/denven/oauthopencallback) the code and serve a local redirect url.

3. set up the required Graph API permissions
![Set up API credentials](./screenshots/API_permissions_1.png)
![Set up API credentials](./screenshots/API_permissions_2.png)

4. get your application client id and tenant id
![Get application id and tenant id](./screenshots/client_id_tenant_id.png)

5. create a client secret and save it for next steps
![Get client credential](./screenshots/client_secret.png)


### Use the repository code to upload your media files
1. clone the repository code to your local computer and enter the code directory
2. use the data fetched from Azure application settings to fill in your `config.json` file on your local machine before uploading the code. Please refer to the following example to edit the `config.json` file in your directory:
```Json
{
  "grant_type": "authorization_code",
  "client_id": "9083c44f-605d-4d31-9d16-955e48d69965",
  "client_secret": "dFE8Q~bUtscYyoTUCxt3RLawrfsnyVGARFhGdcH7",
  "tenant_id": "e2a801f7-46fe-4dcf-91b7-6d4409c7760e",
  "scope": "https://graph.microsoft.com/.default",
  "video_root_folder": "yihack_videos"
}
```
- configuration key and value description
  
|     Configuration key   |      default value      |     Required       |     note       |
| :---------------------: | :---------------------: | :----------------: | :----------------: |
|    grant_type | authorization_code | true |
|    client_id | none | true |
|    client_secret | none | true |
|    tenant_id | none | true |
|    scope | https://graph.microsoft.com/.default | false |
|    video_root_folder | yihack_videos | false |
|    auto_clean_threshold | 90 | false | not supported yet
|    enable_idle_transfer | false | false |


3. upload the code to your camera sd card via `ssh` with `root` account or a FTP tool, target path: `/tmp/sd/yi-hack`, make sure you've uploaded the required files to `/tmp/sd/yi-hack/onedrive`:
   - `init.sh`
   - `config.json`
   - `scripts` directory: with 4 shell script files inside: `api.sh`, `oauth2.sh`, `upload.sh`, `utils.sh`
```bash
cd /tmp/sd/yi-hack
/tmp/sd/yi-hack # ls -R onedrive/
onedrive/:
config.json  init.sh      scripts

onedrive/scripts:
api.sh     oauth2.sh  upload.sh  utils.sh
```

4. sign in your organization [Microsoft Azure](https://login.microsoftonline.com/) account first
5. run the entry Shell script `init.sh` to get uploader program authorization code and complete initializations.

```bash
cd /tmp/sd/yihack/onedrive/
./init.sh
```
![Ahthorize uploader](./screenshots/application_authorization.png)

- Follow the URL redirections to get the authorization code and copy it to your camera terminal.
- Now, you've set up yourOneDrive uploader. The program may throw some information or error on your terminal, some error like `curl: option --data-binary: out of memory` are tolerable and has no issue to file upload.

5. optional: reboot your camera

## Todo list
- [ ] Auto-clean the oldest uploaded folders before the drive space is exhausted