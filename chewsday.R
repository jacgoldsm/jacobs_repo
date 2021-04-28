library(twitteR)

setup_twitter_oauth(consumer_key = "",
                    access_token = "",
                    consumer_secret = "",
                    access_secret = "")

tw <- updateStatus("Oi, it's Chewsday, innit?")
