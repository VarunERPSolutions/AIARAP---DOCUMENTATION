# Payment Provider Abstraction

AR payment processing uses Stripe for Phase 1, but is implemented behind a generic Payment Provider interface rather than calling the Stripe SDK directly throughout the application. This avoids a full rewrite of payment code when a second processor is added later (e.g., for a Tenant-specific merchant relationship or regional coverage Stripe doesn't serve well) — new providers are added as adapters implementing the same interface.
