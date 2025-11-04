import { ServiceNowClient } from '../../src/integration/servicenow-client';
import { AADProvisioning } from '../../src/integration/aad-provisioning';
import { mapUserData } from '../../src/integration/data-mapper';

describe('Integration Tests', () => {
    let serviceNowClient: ServiceNowClient;
    let aadProvisioning: AADProvisioning;

    beforeAll(() => {
        serviceNowClient = new ServiceNowClient();
        aadProvisioning = new AADProvisioning();
    });

    test('should fetch user data from ServiceNow', async () => {
        const userData = await serviceNowClient.getUserData('testUser');
        expect(userData).toBeDefined();
        expect(userData.userName).toBe('testUser');
    });

    test('should provision a new user in Azure AD', async () => {
        const userData = await serviceNowClient.getUserData('testUser');
        const mappedData = mapUserData(userData);
        const result = await aadProvisioning.provisionUser(mappedData);
        expect(result).toBeTruthy();
    });

    test('should update an existing user in Azure AD', async () => {
        const userData = await serviceNowClient.getUserData('existingUser');
        const mappedData = mapUserData(userData);
        const result = await aadProvisioning.updateUser(mappedData);
        expect(result).toBeTruthy();
    });
});