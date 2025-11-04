export const settings = {
    serviceNow: {
        apiUrl: process.env.SERVICENOW_API_URL || 'https://your-instance.service-now.com/api/now/table/user',
        authToken: process.env.SERVICENOW_AUTH_TOKEN || '',
    },
    azureAD: {
        apiUrl: process.env.AZURE_AD_API_URL || 'https://graph.microsoft.com/v1.0/users',
        authToken: process.env.AZURE_AD_AUTH_TOKEN || '',
    },
    logging: {
        level: process.env.LOG_LEVEL || 'info',
    },
};