# ServiceNow to Azure Active Directory Integration

This project facilitates the integration between ServiceNow and Azure Active Directory (AAD) by automating the creation and management of AAD accounts based on user data from ServiceNow.

## Project Structure

- **src/**: Contains the source code for the integration.
  - **integration/**: Holds the core integration logic.
    - `servicenow-client.ts`: Handles communication with the ServiceNow API.
    - `aad-provisioning.ts`: Manages the provisioning of Azure AD accounts.
    - `data-mapper.ts`: Transforms user data between ServiceNow and Azure AD formats.
  - **scripts/**: Contains scripts for executing integration tasks.
    - `create-aad-accounts.ts`: Orchestrates the creation of Azure AD accounts.
    - `sync-validation.ts`: Validates the synchronization process between ServiceNow and Azure AD.
  - **config/**: Configuration settings for API endpoints and authentication.
    - `settings.ts`: Exports configuration settings required for connections.
  - **types/**: TypeScript interfaces defining data structures.
    - `index.ts`: Exports interfaces like `User` and `ServiceNowResponse`.

- **pipelines/**: Contains Azure DevOps pipeline configurations.
  - `azure-pipelines.yml`: Defines the build and deployment steps.
  - **templates/**: Holds reusable pipeline templates.
    - `integration-stage.yml`: Outlines the integration stage steps.
    - `deployment-stage.yml`: Details the deployment stage steps.

- **tests/**: Contains test files for ensuring code quality.
  - **unit/**: Unit tests for individual components.
    - `integration.test.ts`: Tests for integration logic.
  - **integration/**: End-to-end tests for the entire integration flow.
    - `e2e.test.ts`: Validates the complete integration process.

- **.env.example**: Example environment variables needed for the project.
- **package.json**: Configuration file for npm dependencies and scripts.
- **tsconfig.json**: TypeScript configuration file specifying compiler options.

## Setup Instructions

1. Clone the repository:
   ```
   git clone <repository-url>
   cd servicenow-aad-integration
   ```

2. Install dependencies:
   ```
   npm install
   ```

3. Configure environment variables:
   - Copy `.env.example` to `.env` and fill in the required values.

4. Run the integration scripts:
   ```
   npm run create-aad-accounts
   ```

## Usage Guidelines

- Ensure that you have the necessary permissions in both ServiceNow and Azure AD to perform user provisioning.
- Review the scripts and configuration files to customize the integration according to your organization's requirements.
- Use the provided test files to validate the integration logic before deploying to production.

## Contributing

Contributions are welcome! Please submit a pull request or open an issue for any enhancements or bug fixes.