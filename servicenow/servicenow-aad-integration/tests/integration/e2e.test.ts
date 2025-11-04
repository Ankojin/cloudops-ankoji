import { ServiceNowClient } from '../../src/integration/servicenow-client';
import { AADProvisioning } from '../../src/integration/aad-provisioning';
import { mapUserData } from '../../src/integration/data-mapper';

describe('End-to-End Integration Tests', () => {
    let serviceNowClient: ServiceNowClient;
    let aadProvisioning: AADProvisioning;

    beforeAll(() => {
        serviceNowClient = new ServiceNowClient();
        aadProvisioning = new AADProvisioning();
    });

    test('should provision a new user from ServiceNow to Azure AD', async () => {
        const userData = await serviceNowClient.getUserData('testUserId');
        const mappedData = mapUserData(userData);
        const result = await aadProvisioning.provisionUser(mappedData);

        expect(result).toHaveProperty('id');
        expect(result).toHaveProperty('userPrincipalName', mappedData.userPrincipalName);
    });

    test('should update an existing user in Azure AD', async () => {
        const userData = await serviceNowClient.getUserData('existingUserId');
        const mappedData = mapUserData(userData);
        const result = await aadProvisioning.updateUser(mappedData);

        expect(result).toHaveProperty('id', mappedData.id);
        expect(result).toHaveProperty('displayName', mappedData.displayName);
    });

    test('should handle errors when provisioning a user', async () => {
        const invalidUserData = { /* invalid data structure */ };
        await expect(aadProvisioning.provisionUser(invalidUserData)).rejects.toThrow();
    });
});