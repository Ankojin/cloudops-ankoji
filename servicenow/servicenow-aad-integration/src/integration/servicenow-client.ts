class ServiceNowClient {
    private apiUrl: string;
    private authToken: string;

    constructor(apiUrl: string, authToken: string) {
        this.apiUrl = apiUrl;
        this.authToken = authToken;
    }

    async getUserData(userId: string): Promise<any> {
        const response = await fetch(`${this.apiUrl}/api/now/table/sys_user/${userId}`, {
            method: 'GET',
            headers: {
                'Authorization': `Bearer ${this.authToken}`,
                'Content-Type': 'application/json'
            }
        });

        if (!response.ok) {
            throw new Error(`Error fetching user data: ${response.statusText}`);
        }

        const data = await response.json();
        return data.result;
    }

    async createUser(userData: any): Promise<any> {
        const response = await fetch(`${this.apiUrl}/api/now/table/sys_user`, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${this.authToken}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(userData)
        });

        if (!response.ok) {
            throw new Error(`Error creating user: ${response.statusText}`);
        }

        const data = await response.json();
        return data.result;
    }
}

export default ServiceNowClient;