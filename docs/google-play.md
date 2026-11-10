# Google Play and Inquiline

Inquiline doesn't include Google Play, because Google's apps can't be redistributed without Google's permission. You can add it yourself in a few steps.

## Install Google Play

You need about 1.3 GB of free disk space: a 500 MB download, and about 750 MB once installed. Inquiline installs only what the Play Store needs, and leaves out the rest of the package: the Google search app, Digital Wellbeing, TalkBack, Android Auto, backup restore and the setup wizard.

1. Open Inquiline. It appears in the menu bar.
2. Choose **Install Google Play…** from Inquiline in the menu bar, then **Open Download Page**.
3. Download the `MindTheGapps-15.0.0-arm64-….zip` file from the [MindTheGapps page](https://github.com/MindTheGapps/15.0.0-arm64/releases/latest). Keep it zipped. If your browser unpacks it, download it again without unpacking.
4. Choose **Install Google Play…** again, then **Choose Zip…**, and select the file.
5. Wait for Android to restart. This took about a minute in our test, and **Play Store** then appears in Launchpad and in your Applications folder.
6. Open **Play Store** and sign in. We recommend a spare Google account, because Google hasn't certified this device and may limit it or your account.

You can delete the zip afterwards. Installing closes any open apps.

### If Google says the device isn't certified

Our test account signed in without this step. If you're blocked, Google has a [registration page](https://www.google.com/android/uncertified) for devices like this one. We haven't needed it, so the steps aren't verified.

### Remove Google Play

Choose **Remove Google Play…** from Inquiline in the menu bar, or move Play Store to the Trash. Android restarts, and Google's apps, their data and your signed-in account are removed from Android. Apps you installed from the Play Store stay, but those that need Google may stop working.

## What we tested

| Works in our test | Not tested |
|---|---|
| Signing in without registering the device | Sign-in inside games |
| Installing apps from the Play Store | Purchases |
| A game downloading its own data | Apps that check Play Integrity |
| Staying installed after a restart | |
| Removing it completely | |

## Why dragging in an APK isn't enough

The Play Store is one part of a set of Google software:

- **Google Play Store** (`com.android.vending`) is the store you see.
- **Google Play Services** (`com.google.android.gms`) does the actual work: sign-in, licensing, notifications, maps and more.
- **Google Services Framework** (`com.google.android.gsf`) ties the device to Google.

On a phone these come built into the system, with privileged permissions. An APK you add is installed as an ordinary app without those permissions.

### What the "27 S" or "BUNDLE" label means

On APK download sites, these labels mean one app split into several files: the main app, code for each processor, graphics for each screen and languages. **These parts aren't the missing Google components.** Google Play Services is a separate app that isn't in the Play Store's package.

## Without Google Play

### Install single-file APKs

Choose **Add APK…** from Inquiline in the menu bar, or open the `.apk` file. On download sites, choose a variant without a `BUNDLE` label. `.apkm`, `.xapk` and `.apks` files aren't supported yet.

Apps that don't depend on Google Play Services are the most likely to work.

### Get apps from F-Droid

[F-Droid](https://f-droid.org) is a catalog of free and open-source apps, and it runs in Inquiline.

### Try Aurora Store (untested)

[Aurora Store](https://f-droid.org/packages/com.aurora.store/) is an open-source client for Google Play's catalog. It's available from F-Droid and doesn't need Google Play Services.

Things to know before using it:

- It downloads apps from Google's servers, and this may be against Google's terms of service. Read its anonymous and account login options, and don't use a Google account you can't afford to lose.
- Paid apps need an account that owns them.
- It doesn't add Google Play Services, so apps that require them may still fail.

## Apps that need Google Play Services

Without Google Play, these may refuse to start, or start with some features broken:

- Google sign-in, including in games
- In-app purchases and license checks
- Push notifications
- Google Maps inside other apps
- Apps that check Play Integrity, such as many banking, payment and some online games

Installing Google Play should fix some of these. Apps that check Play Integrity would probably still fail, because Inquiline's Android isn't a Google-certified device.

## Risks

- Only download the zip from the official MindTheGapps page. Its files run with high privileges.
- Google could restrict an account or device that it considers uncertified.
- If Android stops starting after a change, deleting `~/Library/Application Support/Inquiline` restores it, but **also deletes all installed apps and their data**.
