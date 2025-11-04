export function mapUserData(serviceNowUser: any): any {
    return {
        displayName: serviceNowUser.name,
        mail: serviceNowUser.email,
        userPrincipalName: serviceNowUser.email,
        givenName: serviceNowUser.first_name,
        surname: serviceNowUser.last_name,
        jobTitle: serviceNowUser.title,
        department: serviceNowUser.department,
        accountEnabled: true,
    };
}