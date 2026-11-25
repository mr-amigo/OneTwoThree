-- Which timestamp decides the dt partition of an event?
SELECT
  count(*) AS events,
  count_if(substr(receivedat, 1, 10) = dt) AS dt_is_received_day,
  count_if(substr(modifieddate, 1, 10) = dt) AS dt_is_event_day,
  count_if(substr(createddate, 1, 10) = dt) AS dt_is_created_day
FROM payment_events
