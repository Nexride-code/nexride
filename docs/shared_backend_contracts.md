# NexRide Shared Backend Contracts

## 1) `ride_requests/{rideId}`

- `ride_id` (string)
- `rider_id` (string)
- `driver_id` (string; `waiting`/empty before assignment)
- `status` (string; `searching`, `accepted`, `arriving`, `arrived`, `on_trip`, `completed`, `cancelled`)
- `trip_state` (string; canonical lifecycle state)
- `market` (string slug)
- `market_pool` (string slug, same as `market` while open-pool)
- `pickup` (map `{lat,lng,address,...}`)
- `dropoff` (map `{lat,lng,address,...}`)
- `created_at` (server timestamp)
- `accepted_at` (server timestamp or null)
- `expires_at` (millis)

## 2) `ride_chats/{rideId}/messages/{messageId}`

- `message_id` (string)
- `ride_id` (string)
- `sender_id` (string)
- `sender_role` (`rider|driver`)
- `type` (`text|image`)
- `text` (string)
- `image_url` (string)
- `created_at` (server timestamp)
- `created_at_client` (millis)
- `status` (`sending|sent|failed|read`)
- `read` (bool)
- `local_temp_id` (string)

Storage path for chat images (Firebase-only):
- `ride_chats/{rideId}/{senderUid}/{fileName}`
- `image_url` stores `getDownloadURL()` output.

## 3) `users/{uid}/payment_methods/{methodId}`

- `id` (string)
- `riderId` (string)
- `provider` (`paystack_ready|flutterwave_ready|...`)
- `provider_reference` (string; integration reference)
- `token_ref` (string; provider token/reference only)
- `type` (`card|bank`)
- `displayTitle` (string)
- `detailLabel` (string)
- `maskedDetails` (string)
- `last4` (string)
- `country` (string; `NG` by default)
- `status` (`linked`)
- `isDefault` / `is_default` (bool)
- `createdAt` / `created_at` (server timestamp)
- `updatedAt` / `updated_at` (server timestamp)

## 4) `users/{uid}/verification`

- `phone_verified` (bool)
- `email_verified` (bool)
- `identity_status` (string)
- `payment_verified` (bool)
- `risk_status` (string)
- `restriction_reason` (string)
- `updated_at` (server timestamp)

## 5) `users/{uid}/trip_history/{tripId}`

- `ride_id` (string)
- `status` (string)
- `fare` (number)
- `distance_km` (number)
- `pickup_address` (string)
- `dropoff_address` (string)
- `created_at` (server timestamp)
- `completed_at` (server timestamp, optional)
