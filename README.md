# OneDrive-uploader for Yi IP Cameras

### To visitors and cloners:
- Any issue is welcome if you find a bug or have a question to ask
- Test feedback on your camera is invaluable to all users at anytime
- Please note that OneDrive resumable API for uploading file larger than 4MB is not very reliable for my case, see [issue](https://github.com/denven/yihack-onedrive-uploader/issues/6). However, YMMV.
- A star 🌟 from you is the best encouragement to me if you think this repository helps you.

This repository is inspired by [roleoroleo](https://github.com/roleoroleo)'s [yi-hack-MStar.gdrive uploader](https://github.com/roleoroleo/yi-hack-MStar.gdrive). The gdrive uploader does provide some convenience, however, my Google drive has only 15GB space shared with Gmail and other account applications, and it is very easy to get storage fully packed with uploaded media files. Fortunately, I've subscribed Microsoft 365 Developer Program which provides 5TB storage space. I think uploading files to OneDrive is a better option for me.

If you have a subscription of Microsoft OneDrive Stroage or Microsoft 365 Developer Program, you will get more storage space, which can allow you to store your camera videos and pictures to it other than paying an expensive manufacturer's storage premium plan.

## Features
- much easier to set up on your camera
  - use a JSON file to configure
  - only few instructions you need to run on your terminal
- unattended upload your video (.mp4) and image (.jpg) files once set up successfully
- both personal and tenant Microsoft accounts are supported
- auto organize uploaded folders into multi-levels by months and dates
- safe auto-clean of your earliest files when storage reaches the specified threshold
- Re-transmission control is used to assure files upload reliability

## Supported camera models
> Yi cameras hacked with the same file hiearacy or builtin applications are more likely to be supported. Anyway, your own separate tests are necessary before you use it. I've tested on my own camera.
  - [x] model y201c(Yi 1080p Dome BFUS) with firmware 4.6.0.0A_201908271549 and yi-hack-MStar 0.4.7 by [denven](https://github.com/denven)
  - [x] model y623(Yi 1080p Pro 2K YFUS) with firmware 12.0.51.08_202403081746 and Allwinner v2 firmware v0.3.2 by @[mrxyzl](https://github.com/mrxyzl)
  - [x] model y21ga(Yi 1080p Home IFUS) with firmware 9.0.19.09_202010291747 and Allwinner v2 firmware 0.3.3 by @[kosauser](https://github.com/kosauser)

  - [ ] welcome to test it on your camera :smile:

## How to use the uploader?
### Prerequisites
1. make sure you've hacked your camera with the matched firmware, please check [yi-hack-MStar](https://github.com/roleoroleo/yi-hack-MStar) or [yi-hack-Allwinner-v2](https://github.com/roleoroleo/yi-hack-Allwinner-v2)
2. you have an OneDrive account assosiated with your [Microsoft Azure](https://portal.azure.com/) account, you'd better have some knowledge of using the Azure portal.


### Create Azure application for your uploader
1. use [App registrations](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade) to register an application on Azure portal 
  - for the `Supported account types` choice: choose `Accounts in this organizational directory only` if your are a Azure Directory Single tenant; choose `Personal Microsoft accounts only` if you are using your own Personal OneDrive.
  - for the **Redirect URI** setting, choose **`WEB`** type and put a live redirectable URL, you can clone [OAuth2 callback](https://github.com/denven/oauthopencallback) and use the code to serve a local redirect url `http://localhost:8080/callback`  
![Register application](./screenshots/register_application.png)


2. set up the required Graph API permissions
- For business/organization tenant user, add `Files.ReadWrite.All`
![Set up API Permissions](./screenshots/API_permissions_1.png)
![Set up API Permissions](./screenshots/API_permissions_2.png)
- For personal account user, add `Files.ReadWrite` and `Files.ReadWrite.All`
![Set up API Permissions](./screenshots/API_permissions_Personal.png)


3. get your application client id, and tenant id (used for tenant account only, ignore it for personal account)
![Get application id and tenant id](./screenshots/client_id_tenant_id.png)

4. create a client secret and save the secret **Value** for next steps
![Get client credential](./screenshots/client_secret.png)

5. Authentication setting for personal account type only
![Authentication](./screenshots/personal_authentication.png)   

### Use the repository code and setup on your camera
1. clone the repository code to your local computer and enter the code directory
2. use the data fetched from Azure application to fill in your `config.json` file before uploading the files to camera. Please refer to the following example to edit the `config.json` file in your directory:
```Json
{
  "grant_type": "authorization_code",
  "client_id": "9083c44f-605d-4d31-9d16-955e48d69965",
  "client_secret": "dFE8Q~bUtscYyoTUCxt3RLawrfsnyVGARFhGdcH7",
  "tenant_id": "e2a801f7-46fe-4dcf-91b7-6d4409c7760e",
  "scope": "https://graph.microsoft.com/.default",
  "video_root_folder": "yihack_videos",
  "convert_utc_path_name": "false",
  "auto_clean_threshold": "100",
  "enable_idle_transfer": "false"
}
```

  
|     Configuration key   |      Default value      |    Description      |
| :---------------------: | :---------------------: |  :----------------: |
|    grant_type | authorization_code | 
|    client_id | "" |  fill in with your data
|    client_secret | "" | fill in with your data
|    tenant_id | "" | for personal account, set it as "consumers"; for tenant account, set a specific tenant id
|    scope | https://graph.microsoft.com/.default | not required
|    video_root_folder | yihack_videos |  name string without white spaces, just **let this program to create it for you** on your OneDrive
|    upload_video_only | true | not required; set it false will upload *.jpg files in the record folders
|    convert_utc_path_name | false | not required; set it to true if you don't like the uploaded folders are in UTC time (for firmware v0.4.9 and later)
|    auto_clean_threshold | 100 |  disabled by default; setting a value in range [50, 100) will enable this feature
|    enable_idle_transfer | false |  setting to true has chances of files upload delayed
|    video_root_folder_id | "" |  auto-filled value when your root upload folder is created by this program, DO NOT fill it manually if you dont know your root upload folder id.


3. upload code and dependent files to your camera sd card via `ssh` with `root` account or a FTP tool, the target path: `/tmp/sd/yi-hack`:
   - create an empty directory named `onedrive` in path `/tmp/sd/yi-hack`
   - upload `init.sh`, `stop.sh` and `scripts` and `bin` directory to `/tmp/sd/yi-hack/onedrive`
   - upload your own `config.json` file to `/tmp/sd/yi-hack/onedrive`

4. sign in your [Microsoft Azure](https://login.microsoftonline.com/) account first
5. run the entry Shell script `init.sh` to complete the application authorization grant flow

```bash
cd /tmp/sd/yi-hack/onedrive/
./init.sh
```
![Ahthorize uploader](./screenshots/application_authorization.png)

- Follow the URL redirections to consent, sign in, etc. and then you will get a authorization code, copy the code to your camera terminal and continue.
- Now, you've set up yourOneDrive uploader. The script will begin to search media files not uploaded from camera sd card to upload, it may throw some information or error messages on your terminal. Error message like `curl: option --data-binary: out of memory` is tolerable and has no issue to the file upload.
![Successful configuration](./screenshots/successful_configuration.png)
- Check your uploaded folder structure, you will find folders are organized by months and dates, which are more convenient to find and view.
![Successful configuration](./screenshots/organize_uploaded_folders.png)
- Check auto-clean logs (the earliest folder-hourly video folder will be deleted first when your storage usage exceeded the specified threshhold ratio).
![image](https://github.com/user-attachments/assets/329adca6-2fa3-4b6f-92ce-c22949a3fad5)


6. optional: reboot your camera
```bash
reboot -f # reboot without -f option cannot work on my camera
```

## Maintenance 

- In case you run into an issue or you just want to stop the uploader, run the `stop.sh` script to kill the running uploader.
  
```bash
cd /tmp/sd/yi-hack/onedrive
./stop.sh
```

- You might have messed up the configuration or you are not content with the running situation, you want to start again from the beginning.
  - first, stop the uploader first by following above;
  - delete all generated data (or keep file `data/last_upload.json` if you want the uploader to resume your uploading without any repetitive uploads);
  - run `./init.sh` again to get your access tokens again;
  - reboot the camera to run it unattendedly with the new configuration.
```bash
rm -rf data
rm -rf log
./init.sh  
reboot -f
```
  - If you want to setup with another OneDrive account (or Azure application data), you can delete or edit your current `config.json`, or replace it with a new one as well.
- Once you have deleted `data` directory or changed application credentials in `config.json` files, you must run the `init.sh` script manually to setup or reload your uploader again.
```bash
./init.sh
reboot -f
```

- :warning: be cautious to delete file `./data/last_upload.json` if you want to restart the uploader and resume the upload to avoid repeatitive upload of all recorded files.
