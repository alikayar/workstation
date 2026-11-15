from services.billing import calculate_total as billing_total


def submit_order(amount: int) -> int:
    return billing_total(amount)
