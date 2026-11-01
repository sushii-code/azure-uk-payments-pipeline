# Creates one day of fake card payments as a CSV file, including planted fraud and dirty data.
# Example: python simulator/generate_payments.py --date 2026-10-30 --rows 2000

# argparse reads the options typed on the command line, like --date and --rows
import argparse

# csv writes the rows in the correct CSV format
import csv

# math gives us log(), which the amount calculation needs
import math

# random makes the fake data
import random

# datetime and timedelta let us work with dates and add minutes to times
from datetime import datetime, timedelta

# Path handles file locations and works on both Windows and Mac/Linux
from pathlib import Path


# The column names, in the order they appear in the CSV file
COLUMNS = [
    "transaction_id",
    "txn_timestamp",
    "card_id",
    "customer_id",
    "card_home_country",
    "merchant_id",
    "merchant_name",
    "merchant_category",
    "merchant_country",
    "amount",
    "currency",
    "channel",
    "status",
]

# Roughly how much of each currency 1 GBP buys, so foreign amounts are realistic
# These are fixed on purpose: the real rates come from the FX feed, not from this script
GBP_RATES = {
    "GBP": 1.0,
    "EUR": 1.20,
    "USD": 1.34,
    "INR": 127.0,
    "JPY": 211.0,
    "AUD": 1.91,
    "CAD": 1.87,
}

# Which currency each merchant country uses
COUNTRY_CURRENCY = {
    "GB": "GBP",
    "FR": "EUR",
    "DE": "EUR",
    "ES": "EUR",
    "IE": "EUR",
    "US": "USD",
    "IN": "INR",
    "JP": "JPY",
    "AU": "AUD",
    "CA": "CAD",
}

# Where cards spend abroad, and how likely each place is
# Together with the 75% GB chance below, this gives about 75% GBP overall
FOREIGN_COUNTRIES = ["FR", "DE", "ES", "IE", "US", "IN", "JP", "AU", "CA"]
FOREIGN_WEIGHTS = [3, 2, 3, 2, 6, 3, 2, 2, 2]

# Each category has: fake shop names, a typical amount in GBP, how much amounts vary,
# how often the category is used, and how likely a payment is to be online
CATEGORIES = {
    "groceries": {"names": ["Greenleaf Grocers", "Daily Basket"], "typical": 25, "spread": 0.5, "weight": 30, "online": 0.10},
    "restaurants": {"names": ["The Copper Spoon", "Olive and Thyme"], "typical": 30, "spread": 0.5, "weight": 20, "online": 0.15},
    "fuel": {"names": ["Northway Fuel", "Roadside Energy"], "typical": 50, "spread": 0.3, "weight": 10, "online": 0.00},
    "clothing": {"names": ["Thread and Needle", "Harbour Clothing"], "typical": 45, "spread": 0.6, "weight": 15, "online": 0.50},
    "entertainment": {"names": ["Lantern Cinemas", "Pixel Streaming"], "typical": 15, "spread": 0.5, "weight": 15, "online": 0.60},
    "electronics": {"names": ["Volt Electronics", "Circuit House"], "typical": 250, "spread": 0.7, "weight": 6, "online": 0.60},
    "travel": {"names": ["Skyline Travel", "Bluewave Holidays"], "typical": 350, "spread": 0.7, "weight": 4, "online": 0.85},
}

# More payments happen in the daytime: one weight for each hour, from midnight to 11pm
HOUR_WEIGHTS = [1, 1, 1, 1, 1, 2, 4, 7, 10, 12, 13, 14, 15, 14, 13, 13, 14, 15, 14, 12, 9, 6, 4, 2]

# Normal payments stop at this amount, so they can never look like a high-amount fraud
NORMAL_MAX_GBP = 1500

# High-amount fraud starts well above 2,000 GBP, so it stays over 2,000 when real FX rates move
HIGH_AMOUNT_MIN_GBP = 2500
HIGH_AMOUNT_MAX_GBP = 9000

# How many of each fraud type to plant
HIGH_AMOUNT_COUNT = 10
VELOCITY_CARD_COUNT = 3
TRAVEL_CARD_COUNT = 3

# Contactless payments are limited to small amounts in real life
CONTACTLESS_LIMIT_GBP = 100

# Text that is clearly not a valid timestamp, for the dirty data
BAD_TIMESTAMPS = ["not-a-timestamp", "2026-13-45T25:61:00Z", "30/10/2026 14:05", "yesterday"]


def build_merchants():
    """Make the merchant list, which is the same every day."""
    # Start with an empty list and a number for the merchant IDs
    merchants = []
    number = 1

    # Create every shop name in every country
    for country in COUNTRY_CURRENCY:
        for category, details in CATEGORIES.items():
            for name in details["names"]:
                # Save this merchant, then move on to the next ID
                merchants.append(
                    {
                        "merchant_id": f"M{number:04d}",
                        "merchant_name": name,
                        "merchant_category": category,
                        "merchant_country": country,
                    }
                )
                number += 1

    return merchants


def build_cards(rows, rng):
    """Make the cards and decide which country each one spends in today."""
    # Use about one card for every 4 payments, with at least 30 cards
    card_count = max(30, rows // 4)
    cards = []

    for number in range(1, card_count + 1):
        # A separate random generator per card keeps its home country the same every day
        card_rng = random.Random(f"card-{number}")
        home = "GB" if card_rng.random() < 0.90 else card_rng.choice(["IE", "FR", "US", "IN", "DE"])

        # 75% of cards spend in GB today; the rest spend in one foreign country all day
        # Staying in one country stops normal cards from looking like "impossible travel" fraud
        if rng.random() < 0.75:
            spend_country = "GB"
        else:
            spend_country = rng.choices(FOREIGN_COUNTRIES, FOREIGN_WEIGHTS)[0]

        # Every 5 cards share 4 customers, so a few customers own two cards
        cards.append(
            {
                "card_id": f"card_{number:04d}",
                "customer_id": f"cust_{1 + (number - 1) * 4 // 5:04d}",
                "card_home_country": home,
                "spend_country": spend_country,
            }
        )

    return cards


def random_time(day, rng):
    """Pick a time in the day, with more payments in the daytime."""
    # Choose an hour using the weights, then any minute and second within it
    hour = rng.choices(range(24), HOUR_WEIGHTS)[0]
    return day + timedelta(hours=hour, minutes=rng.randrange(60), seconds=rng.randrange(60))


def pick_merchant(merchants, country, category, rng):
    """Pick a merchant from this country and category."""
    # Keep only matching merchants, then choose one at random
    matches = [m for m in merchants if m["merchant_country"] == country and m["merchant_category"] == category]
    return rng.choice(matches)


def pick_channel(category, amount_gbp, rng):
    """Choose how the card was used."""
    # Some categories are more likely to be online, such as travel
    if rng.random() < CATEGORIES[category]["online"]:
        return "online"

    # Over the contactless limit, the card has to be used in the shop
    if amount_gbp > CONTACTLESS_LIMIT_GBP:
        return "in_store"

    # Small payments in shops are a mix of the two
    return rng.choice(["in_store", "contactless"])


def make_row(card, merchant, when, amount_gbp, channel, status, is_planted_fraud):
    """Build one payment row, converting the amount into the merchant's currency."""
    # Look up the currency from the merchant's country
    currency = COUNTRY_CURRENCY[merchant["merchant_country"]]

    # The ID is added later, once the rows are in time order
    return {
        "transaction_id": "",
        "txn_timestamp": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "card_id": card["card_id"],
        "customer_id": card["customer_id"],
        "card_home_country": card["card_home_country"],
        "merchant_id": merchant["merchant_id"],
        "merchant_name": merchant["merchant_name"],
        "merchant_category": merchant["merchant_category"],
        "merchant_country": merchant["merchant_country"],
        "amount": f"{amount_gbp * GBP_RATES[currency]:.2f}",
        "currency": currency,
        "channel": channel,
        "status": status,
        # This marker is not written to the CSV; it keeps dirty data away from fraud rows
        "is_planted_fraud": is_planted_fraud,
    }


def make_normal_row(cards, merchants, day, rng):
    """Create one ordinary payment."""
    # Pick a card, and a category using the weights
    card = rng.choice(cards)
    category = rng.choices(list(CATEGORIES), [c["weight"] for c in CATEGORIES.values()])[0]
    merchant = pick_merchant(merchants, card["spend_country"], category, rng)

    # A log-normal amount gives many typical payments and a few bigger ones
    details = CATEGORIES[category]
    amount_gbp = rng.lognormvariate(math.log(details["typical"]), details["spread"])

    # Keep the amount between 1 GBP and the normal maximum
    amount_gbp = min(max(amount_gbp, 1), NORMAL_MAX_GBP)

    # About 5% of normal payments are declined
    status = "declined" if rng.random() < 0.05 else "approved"
    channel = pick_channel(category, amount_gbp, rng)
    return make_row(card, merchant, random_time(day, rng), amount_gbp, channel, status, False)


def make_high_amount_rows(cards, merchants, day, rng):
    """Plant fraud: very large payments on ordinary cards."""
    rows = []

    # Each big payment goes on a different card
    for card in rng.sample(cards, HIGH_AMOUNT_COUNT):
        # Big payments fit these categories best, and are usually made online
        category = rng.choice(["electronics", "travel"])
        merchant = pick_merchant(merchants, card["spend_country"], category, rng)
        amount_gbp = rng.uniform(HIGH_AMOUNT_MIN_GBP, HIGH_AMOUNT_MAX_GBP)
        rows.append(make_row(card, merchant, random_time(day, rng), amount_gbp, "online", "approved", True))

    return rows


def make_velocity_rows(cards, merchants, day, rng):
    """Plant fraud: cards making 6 or more payments within 10 minutes."""
    rows = []

    for card in cards:
        # Start at some point during the day, and make 6 to 8 payments
        start = day + timedelta(hours=rng.randrange(8, 21), minutes=rng.randrange(60))
        for _ in range(rng.randint(6, 8)):
            # Keep every payment under 9 minutes from the start, so all fit inside 10 minutes
            when = start + timedelta(seconds=rng.randrange(540))
            merchant = pick_merchant(merchants, "GB", rng.choice(["clothing", "entertainment"]), rng)
            amount_gbp = rng.uniform(10, 90)
            rows.append(make_row(card, merchant, when, amount_gbp, "online", "approved", True))

    return rows


def make_travel_rows(cards, merchants, day, rng):
    """Plant fraud: cards paying in GB and then in another country within 1 hour."""
    rows = []

    for card in cards:
        # First, a normal-looking payment in a shop in GB
        first_time = day + timedelta(hours=rng.randrange(8, 21), minutes=rng.randrange(60))
        gb_merchant = pick_merchant(merchants, "GB", "groceries", rng)
        rows.append(make_row(card, gb_merchant, first_time, rng.uniform(10, 60), "in_store", "approved", True))

        # Then a payment in a shop abroad, 15 to 55 minutes later: too soon to have travelled there
        second_time = first_time + timedelta(minutes=rng.randint(15, 55))
        foreign_country = rng.choices(FOREIGN_COUNTRIES, FOREIGN_WEIGHTS)[0]
        foreign_merchant = pick_merchant(merchants, foreign_country, "clothing", rng)
        rows.append(make_row(card, foreign_merchant, second_time, rng.uniform(40, 95), "in_store", "approved", True))

    return rows


def generate(date_text, row_count):
    """Create all the rows for one day and return them with a summary."""
    # Seeding with the date means the same date always gives exactly the same data
    rng = random.Random(date_text)

    # Turn the date text into a real date, at midnight
    day = datetime.strptime(date_text, "%Y-%m-%d")
    merchants = build_merchants()
    cards = build_cards(row_count, rng)

    # Decide how many dirty rows to plant, based on the percentages
    duplicate_count = round(row_count * 0.01)
    empty_amount_count = round(row_count * 0.005)
    bad_timestamp_count = round(row_count * 0.003)
    lowercase_count = max(3, row_count // 400)

    # Velocity and travel fraud need cards that spend in GB
    # The "travel" cards must also be from GB, since Day 5 looks for a GB card going abroad
    gb_cards = [c for c in cards if c["spend_country"] == "GB" and c["card_home_country"] == "GB"]
    fraud_cards = rng.sample(gb_cards, VELOCITY_CARD_COUNT + TRAVEL_CARD_COUNT)
    velocity_cards = fraud_cards[:VELOCITY_CARD_COUNT]
    travel_cards = fraud_cards[VELOCITY_CARD_COUNT:]

    # Keep those cards out of normal payments, so their patterns stay easy to find
    other_cards = [c for c in cards if c not in fraud_cards]

    # Make each type of planted fraud
    high_amount_rows = make_high_amount_rows(other_cards, merchants, day, rng)
    velocity_rows = make_velocity_rows(velocity_cards, merchants, day, rng)
    travel_rows = make_travel_rows(travel_cards, merchants, day, rng)
    rows = high_amount_rows + velocity_rows + travel_rows

    # Fill the rest with normal payments, leaving room for the duplicate rows added later
    normal_count = row_count - duplicate_count - len(rows)
    rows += [make_normal_row(other_cards, merchants, day, rng) for _ in range(normal_count)]

    # Put the rows in time order, like a real payment system would
    rows.sort(key=lambda row: row["txn_timestamp"])

    # Give each row its unique ID, including the date so IDs never repeat across days
    for number, row in enumerate(rows, start=1):
        row["transaction_id"] = f"txn_{date_text.replace('-', '')}_{number:06d}"

    # Choose separate normal rows for each dirty problem, so each row has only one problem
    normal_rows = [row for row in rows if not row["is_planted_fraud"]]
    total_dirty = duplicate_count + empty_amount_count + bad_timestamp_count + lowercase_count
    dirty_rows = rng.sample(normal_rows, total_dirty)

    # Cut the chosen rows into one group per problem
    position_1 = duplicate_count
    position_2 = position_1 + empty_amount_count
    position_3 = position_2 + bad_timestamp_count
    duplicate_sources = dirty_rows[:position_1]
    empty_amount_rows = dirty_rows[position_1:position_2]
    bad_timestamp_rows = dirty_rows[position_2:position_3]
    lowercase_rows = dirty_rows[position_3:]

    # Dirty data: remove the amount
    for row in empty_amount_rows:
        row["amount"] = ""

    # Dirty data: replace the timestamp with text that can't be read as a time
    for row in bad_timestamp_rows:
        row["txn_timestamp"] = rng.choice(BAD_TIMESTAMPS)

    # Dirty data: write the currency code in lowercase
    for row in lowercase_rows:
        row["currency"] = row["currency"].lower()

    # Dirty data: add a copy of each chosen row somewhere random, as if it was sent twice
    for row in duplicate_sources:
        rows.insert(rng.randrange(len(rows) + 1), dict(row))

    # Collect the counts to print at the end
    summary = {
        "total_rows": len(rows),
        "fraud_high_amount_rows": len(high_amount_rows),
        "fraud_velocity_cards": len(velocity_cards),
        "fraud_velocity_rows": len(velocity_rows),
        "fraud_travel_cards": len(travel_cards),
        "fraud_travel_rows": len(travel_rows),
        "dirty_duplicate_rows": len(duplicate_sources),
        "dirty_empty_amount_rows": len(empty_amount_rows),
        "dirty_invalid_timestamp_rows": len(bad_timestamp_rows),
        "dirty_lowercase_currency_rows": len(lowercase_rows),
    }
    return rows, summary


def write_csv(rows, date_text):
    """Save the rows to data/payments_<date>.csv and return the file's location."""
    # Find the project folder from this script's location, so it works from any folder
    project_folder = Path(__file__).resolve().parent.parent
    output_path = project_folder / "data" / f"payments_{date_text}.csv"

    # Create the data folder if it doesn't exist yet
    output_path.parent.mkdir(exist_ok=True)

    # newline="" and a fixed line ending make the file identical on every computer
    with output_path.open("w", newline="", encoding="utf-8") as file:
        # extrasaction="ignore" leaves out the is_planted_fraud marker
        writer = csv.DictWriter(file, fieldnames=COLUMNS, extrasaction="ignore", lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    return output_path


def valid_date(text):
    """Accept only dates written exactly like 2026-10-30."""
    # Try to read the date, and give a helpful message if it's wrong
    try:
        parsed = datetime.strptime(text, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError("date must look like 2026-10-30")

    # Rewriting the date gives 2026-10-30 even if someone typed 2026-10-3, so the seed stays the same
    return parsed.strftime("%Y-%m-%d")


def main():
    """Read the command-line options, create the file and print the summary."""
    # Describe the two options this script needs
    parser = argparse.ArgumentParser(description="Generate one day of fake card payments.")
    parser.add_argument("--date", required=True, type=valid_date, help="Day to generate, like 2026-10-30")
    parser.add_argument("--rows", required=True, type=int, help="Total rows in the file (at least 500)")
    args = parser.parse_args()

    # With too few rows, the planted fraud and dirty data would take over the file
    if args.rows < 500:
        parser.error("--rows must be at least 500")

    # Create the data and save it
    rows, summary = generate(args.date, args.rows)
    output_path = write_csv(rows, args.date)

    # Print where the file went and each count
    print(f"Wrote {output_path}")
    print("Summary")
    for name, count in summary.items():
        print(f"  {name}: {count}")


# Only run main() when this file is run directly, not when another script imports it
if __name__ == "__main__":
    main()
