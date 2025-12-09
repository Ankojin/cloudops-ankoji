Connect-MgGraph -Scopes User.ReadWrite.All

$PasswordProfile = @{
    Password = "Mub#@123"
    ForceChangePasswordNextSignIn = $false
}

Update-MgUser `
  -UserId svc_mbshr_sit@albtests.com `
  -PasswordProfile $PasswordProfile `
  -PasswordPolicies DisablePasswordExpiration