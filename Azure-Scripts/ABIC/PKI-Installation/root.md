certutil -setreg CA\CRLPublicationURLs "http://pki.contoso.com/CertEnroll/%%c%%s.crl"
certutil -setreg CA\CACertPublicationURLs "http://pki.contoso.com/CertEnroll/%%c%%s.crt"
Restart-Service CertSvc

# Set CRL and AIA paths
certutil -setreg CA\CRLPublicationURLs "file://%SystemRoot%\system32\CertSrv\CertEnroll\%%c%%s.crl\nhttp://pki.contoso.com/CertEnroll/%%c%%s.crl"
certutil -setreg CA\CACertPublicationURLs "file://%SystemRoot%\system32\CertSrv\CertEnroll\%%c%%s.crt\nhttp://pki.contoso.com/CertEnroll/%%c%%s.crt"

# Publish CRL
certutil -crl

