SELECT
  AVG(diffPercent)
FROM
  (
    SELECT
      prices.minute,
      prices.price,
      remainingOrders.isLong,
      remainingOrders.triggerAboveThreshold,
      cast(remainingOrders.triggerPrice as double) / 1e30 as TriggerPrice,
      (
        cast(remainingOrders.triggerPrice as double) / 1e30
      ) - prices.price as diff,
      ABS(
        (
          (
            cast(remainingOrders.triggerPrice as double) / 1e30
          ) - prices.price
        ) / prices.price * 100
      ) as diffPercent,
      (
        cast(remainingOrders.triggerPrice as double) / 1e30
      ) - prices.price > 0 isPositive
    FROM
      (
        SELECT
          *
        FROM
          gmx_arbitrum.OrderBook_evt_CreateDecreaseOrder createOrders
        WHERE
          NOT EXISTS (
            SELECT
              *
            FROM
              gmx_arbitrum.OrderBook_evt_CancelDecreaseOrder cancelOrder
            WHERE
              createOrders.account = cancelOrder.account
              AND createOrders.indexToken = cancelOrder.indexToken
              AND createOrders.orderIndex = cancelOrder.orderIndex
              AND createOrders.isLong = cancelOrder.isLong
              AND createOrders.sizeDelta = cancelOrder.sizeDelta
              AND createOrders.triggerPrice = cancelOrder.triggerPrice
              AND createOrders.triggerAboveThreshold = cancelOrder.triggerAboveThreshold
          )
      ) remainingOrders
      JOIN (
        SELECT
          *
        FROM
          prices.usd
        WHERE
          contract_address = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
      ) prices ON remainingOrders.evt_block_time = prices.minute
    WHERE
      indexToken = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
      AND (
        (
          isLong = true
          AND triggerAboveThreshold = false
          AND (
            cast(remainingOrders.triggerPrice as double) / 1e30
          ) - prices.price > 0
        )
        OR (
          isLong = false
          AND triggerAboveThreshold = true
          AND (
            cast(remainingOrders.triggerPrice as double) / 1e30
          ) - prices.price < 0
        )
      )
      AND ABS(
        (
          (
            cast(remainingOrders.triggerPrice as double) / 1e30
          ) - prices.price
        ) / prices.price * 100
      ) < 10
  )