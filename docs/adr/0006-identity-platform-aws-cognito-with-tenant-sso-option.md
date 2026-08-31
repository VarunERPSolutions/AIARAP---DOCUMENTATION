# Identity Platform: AWS Cognito with Per-Tenant SSO Option

User authentication is delegated to AWS Cognito by default rather than building custom password/MFA handling, keeping AIARAP out of the business of storing and securing credentials directly. A Tenant may instead configure their own SSO/identity provider (SAML/OIDC federation) for their own Users rather than using the Cognito-hosted default, accommodating Tenants with existing corporate identity requirements.
