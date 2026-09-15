# Copy this file to publish.local.ps1 and fill in your own values.
# publish.local.ps1 is ignored by Git and must stay only on the admin machine.

@{
    FtpUser     = 'CHANGE_ME'
    FtpPassword = 'CHANGE_ME'
    GitHubToken = 'CHANGE_ME'

    # Optional. Create a separate Gale profile containing ONLY client-side
    # optimization mods (and their configs/dependencies), then put the path to
    # that profile's BepInEx directory here. Leave empty to publish without it.
    # Example:
    # LowSpecGaleBepInExPath = 'C:\Users\username\AppData\Roaming\com.kesomannen.gale\valheim\profiles\Valheim Low Spec\BepInEx'
    LowSpecGaleBepInExPath = ''
}
