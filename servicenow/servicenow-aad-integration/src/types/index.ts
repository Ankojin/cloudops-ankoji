export interface User {
    id: string;
    name: string;
    email: string;
    department?: string;
    title?: string;
}

export interface ServiceNowResponse {
    result: User[];
    status: string;
    error?: string;
}