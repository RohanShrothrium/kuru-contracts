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
      AND createOrders.evt_block_number > 71055844
      AND cancelOrder.evt_block_number > 71055844
  )
  AND createOrders.evt_block_number > 71055844