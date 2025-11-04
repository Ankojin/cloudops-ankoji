import { ServiceNowClient } from '../integration/servicenow-client';
import { AADProvisioning } from '../integration/aad-provisioning';
import { mapUserData } from '../integration/data-mapper';
import { User } from '../types';

async function createAADAccounts() {
    const serviceNowClient = new ServiceNowClient();
    const aadProvisioning = new AADProvisioning();

    try {
        // Fetch user data from ServiceNow
        const users: User[] = await serviceNowClient.getUserData();

        for (const user of users) {
            // Map user data to Azure AD format
            const aadUser = mapUserData(user);

            // Provision the user in Azure AD
            await aadProvisioning.provisionUser(aadUser);
            console.log(`Provisioned user: ${aadUser.displayName}`);
        }
    } catch (error) {
        console.error('Error creating AAD accounts:', error);
    }
}

// Execute the script
createAADAccounts();