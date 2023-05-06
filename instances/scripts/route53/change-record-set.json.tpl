{
    "Comment": "Upsert route53 record for market_data_notification",
    "Changes": [
        {
            "Action": "<ACTION>",
            "ResourceRecordSet": {
                "Name": "<DOMAIN>",
                "Type": "A",
                "TTL": <TTL>,
                "ResourceRecords": [
                    {
                        "Value": "<INSTANCE_IP_ADDRESS>"
                    }
                ]
            }
        }
    ]
}