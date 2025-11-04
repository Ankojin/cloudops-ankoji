// This file contains the sync validation script for validating the synchronization process between ServiceNow and Azure AD.

import { ServiceNowClient } from '../integration/servicenow-client';
import { AADProvisioning } from '../integration/aad-provisioning';
import { mapUserData } from '../integration/data-mapper';

async function validateSync() {
    const serviceNowClient = new ServiceNowClient();
    const aadProvisioning = new AADProvisioning();

    try {
        const serviceNowUsers = await serviceNowClient.getUserData();
        const aadUsers = await aadProvisioning.getAllUsers(); // Assuming this method exists

        const discrepancies = [];

        serviceNowUsers.forEach(user => {
            const mappedUser = mapUserData(user);
            const aadUser = aadUsers.find(aadUser => aadUser.email === mappedUser.email);

            if (!aadUser) {
                discrepancies.push(`User ${mappedUser.email} exists in ServiceNow but not in Azure AD.`);
            } else {
                // Check for other discrepancies, e.g., name, role, etc.
                if (aadUser.name !== mappedUser.name) {
                    discrepancies.push(`User ${mappedUser.email} has a name discrepancy: ServiceNow (${mappedUser.name}) vs Azure AD (${aadUser.name}).`);
                }
            }
        });

        if (discrepancies.length > 0) {
            console.log('Discrepancies found during sync validation:');
            discrepancies.forEach(issue => console.log(issue));
        } else {
            console.log('No discrepancies found. Sync validation successful.');
        }
    } catch (error) {
        console.error('Error during sync validation:', error);
    }
}

validateSync();