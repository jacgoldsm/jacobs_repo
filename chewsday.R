library(twitteR)

setup_twitter_oauth(consumer_key = "bfULkb1d3JI3XfTDQlmph2Z9O",
                    access_token = "1387406382526210060-tLxmXGCmiNhpdxsMqJwlqgUriGgtMe",
                    consumer_secret = "HxfbRiBuvpI6Q4xjo0AbhxB1w9uCrG3DI2nviftby5rocaMIuX",
                    access_secret = "zXSWv8yJHVDdLGUfrvsJrgZnekwPBh14kVKbLKjYXmFjX")

tw <- updateStatus("Oi, it's Chewsday, innit?")
