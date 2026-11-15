from services.shipping import calculate_total


def dispatch(weight: int) -> int:
    return calculate_total(weight)
