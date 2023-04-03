SELECT
  prices.minute,
  prices.price,
  ob.isLong,
  ob.triggerAboveThreshold,
  cast(ob.triggerPrice as double) / 1e30 as TriggerPrice
FROM
  gmx_arbitrum.OrderBook_evt_ExecuteDecreaseOrder ob
  JOIN (
    SELECT
      *
    FROM
      prices.usd
    WHERE
      contract_address = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
  ) prices ON ob.evt_block_time = prices.minute
WHERE
  indexToken = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
  AND (
    (
      isLong = true
      AND triggerAboveThreshold = false
    )
    OR (
      isLong = false
      AND triggerAboveThreshold = true
    )
  )