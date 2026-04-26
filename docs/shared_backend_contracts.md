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

## 6) `shared_trip_lookup/{rideId}` and `shared_trips/{token}`

- `shared_trip_lookup/{rideId}`
  - `ride_id` (string)
  - `token` (string)
  - `created_at` (millis)
  - `expires_at` (millis)
  - `updated_at` (millis)
- `shared_trips/{token}`
  - `share_version` (number)
  - `ride_id` (string)
  - `status` (string)
  - `trip_state` (string)
  - `pickup`, `destination`, `stops`
  - `driver` (sanitized public payload only)
  - `route`, `live_location`
  - `payment.method`, `payment.status`, `payment.settlement_status`, `payment.provider`, `payment.provider_status`
  - `created_at`, `expires_at`, `updated_at`

## 7) Dispatch Upload Metadata (`dispatch_uploads/{rideId}/{category}/{fileId}`)

- `ride_id` (string)
- `uploaded_by` (uid)
- `file_url` (download URL)
- `file_ref` (storage fullPath)
- `content_type` (image mime type)
- `file_size_bytes` (number)
- `category` (`package_photo|delivery_proof|...`)
- `source` (`camera|gallery`)
- `created_at` (server timestamp)
- `updated_at` (server timestamp)

## 8) Operations + Admin Mirrors

- `admin_rides/{rideId}/summary`
  - canonical mirror for: `ride_id`, `rider_id`, `driver_id`, `market`, `status`, `trip_state`, `payment_method`, `payment_status`, `settlement_status`, `support_status`, `created_at`, `accepted_at`, `cancelled_at`, `completed_at`, `cancel_reason`, `updated_at`
- `support_queue/{rideId}`
  - `ride_id`, `rider_id`, `driver_id`, `status`, `trip_state`, `payment_status`, `settlement_status`, `support_status`, `last_event`, `created_at`, `accepted_at`, `cancelled_at`, `completed_at`, `cancel_reason`, `updated_at`

## 9) Support Tickets

- `support_tickets/{ticketId}`
  - `ticketId`, `createdByUserId`, `createdByType`, `subject`, `message`, `category`, `priority`, `status`, `tripId`
  - `requesterProfile`, `counterpartyProfile`, `tripSnapshot`
  - `lastReplyAt`, `lastSupportReplyAt`, `requesterSeenAt`, `lastPublicSenderRole`
  - `createdAt`, `updatedAt`, `resolvedAt`, `closedAt`
- `support_ticket_messages/{ticketId}/{messageId}`
  - `ticketDocumentId`, `senderId`, `senderRole`, `senderName`, `message`, `attachmentUrl`, `visibility`, `createdAt`

## 10) Pricing + Traffic Snapshot (inside `ride_requests/{rideId}`)

- `fare_breakdown` remains base calculation source.
- `pricing_snapshot` is canonical freeze-at-request payload:
  - `serviceKey`, `market`, `baseFare`, `distanceKm`, `durationMin`, `perKmRate`, `perMinuteRate`, `minimumFare`
  - `surgeMultiplier`, `trafficMultiplier`, `trafficWindowLabel`
  - `calculatedFare`, `minimumAdjustedFare`, `finalFare`, `totalFare`
  - `traffic_window`, `distance_km`, `duration_min`, `computed_at`

## 11) Calls Contract (Agora)

- Token source: Firebase Function only.
- Endpoint: `https://us-central1-nexride-8d5bc.cloudfunctions.net/generateAgoraToken`
- Method: `GET`
- Query: `channelName`, `uid` (non-negative integer)
- Success response includes `token`; clients use `ride_<rideId>` channel naming.
- No client-side fallback token servers allowed.

## 12) Flutterwave-Ready Placeholder (No Live Charges)

- `ride_requests/{rideId}/payment_placeholder`
  - `provider` (`flutterwave_ready`)
  - `status` (`placeholder_pending|placeholder_authorized|placeholder_failed`)
  - `intent_id` (string, empty until integration)
  - `tx_ref` (string, empty until integration)
  - `initialized_at`, `updated_at`
- Placeholder fields are metadata only; no PSP charge execution in current phase.
