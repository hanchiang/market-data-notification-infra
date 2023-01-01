{
    "Comment": "Upsert route53 record for url_shortener",
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