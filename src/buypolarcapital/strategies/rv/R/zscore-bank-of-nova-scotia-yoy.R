
library(tidyquant)
library(tidyverse)
library(lubridate)
library(scales)
library(zoo)
library(ggthemes)
library(showtext)

# Font
font_add_google("Montserrat", "gs_font")
showtext_auto()

# SETTINGS
tickerA <- "BNS"      # US listing
tickerB <- "BNS.TO"   # Toronto listing
initial_capital <- 1e7
threshold <- 1
rolling_windows <- c(10, 20, 30, 60)

simulate_strategy <- function(prices, colA, colB, threshold, initial_capital) {
  portfolio <- tibble(date = prices$date, cash = NA, A = NA, B = NA, value = NA)
  first <- prices[1, ]
  
  if (first$z_score > 0) {
    shares_B <- floor(initial_capital / first[[colB]])
    shares_A <- 0
    cash <- initial_capital - shares_B * first[[colB]]
  } else {
    shares_A <- floor(initial_capital / first[[colA]])
    shares_B <- 0
    cash <- initial_capital - shares_A * first[[colA]]
  }
  
  for (i in seq_len(nrow(prices))) {
    row <- prices[i, ]
    z <- row$z_score
    rebalance_now <- (z > threshold && shares_A > 0) || (z < -threshold && shares_B > 0)
    
    if (rebalance_now) {
      value_before <- shares_A * row[[colA]] + shares_B * row[[colB]] + cash
      cash <- value_before
      if (z > 0) {
        shares_A <- 0
        shares_B <- floor(cash / row[[colB]])
        cash <- cash - shares_B * row[[colB]]
      } else {
        shares_B <- 0
        shares_A <- floor(cash / row[[colA]])
        cash <- cash - shares_A * row[[colA]]
      }
    }
    
    value <- shares_A * row[[colA]] + shares_B * row[[colB]] + cash
    portfolio[i, c("cash", "A", "B", "value")] <- list(cash, shares_A, shares_B, value)
  }
  
  return(portfolio)
}

# Load data from 2000 onward
prices <- tq_get(c(tickerA, tickerB), from = "2000-01-01", to = Sys.Date()) %>%
  select(date, symbol, adjusted) %>%
  pivot_wider(names_from = symbol, values_from = adjusted) %>%
  drop_na() %>%
  mutate(year = year(date))

years <- unique(prices$year)
plot_list <- list()

for (yr in years) {
  df_year <- prices %>% filter(year == yr)
  if (nrow(df_year) < max(rolling_windows)) next
  
  yearly_results <- list()
  
  for (win in rolling_windows) {
    df <- df_year %>%
      mutate(
        ratio = !!sym(tickerA) / !!sym(tickerB),
        roll_mean = rollmean(ratio, win, fill = NA, align = "right"),
        roll_sd = rollapply(ratio, win, sd, fill = NA, align = "right"),
        z_score = (ratio - roll_mean) / roll_sd
      ) %>%
      drop_na()
    
    if (nrow(df) < win) next
    
    strat <- simulate_strategy(df, tickerA, tickerB, threshold, initial_capital) %>%
      select(date, value) %>%
      rename(strategy = value)
    
    rebased <- df %>%
      select(date, !!sym(tickerA), !!sym(tickerB)) %>%
      mutate(
        A_val = !!sym(tickerA) / first(!!sym(tickerA)) * initial_capital,
        B_val = !!sym(tickerB) / first(!!sym(tickerB)) * initial_capital
      ) %>%
      select(date, A_val, B_val)
    
    merged <- left_join(strat, rebased, by = "date") %>%
      pivot_longer(cols = c("strategy", "A_val", "B_val"),
                   names_to = "type", values_to = "value") %>%
      mutate(
        type = recode(type, strategy = "Dual Strategy", A_val = tickerA, B_val = tickerB),
        window = paste0(win, "d")
      )
    
    yearly_results[[as.character(win)]] <- merged
  }
  
  all_df <- bind_rows(yearly_results)
  
  color_map <- c(
    "Dual Strategy" = "#003366",
    tickerA = "#b30000",
    tickerB = "#006d2c"
  )
  
  theme_gs <- theme_minimal(base_family = "gs_font") +
    theme(
      plot.title = element_text(face = "bold", size = 16, hjust = 0.5),
      plot.subtitle = element_text(size = 11, hjust = 0.5),
      strip.text = element_text(face = "bold", size = 11),
      axis.title = element_text(size = 11),
      axis.text = element_text(size = 9),
      legend.position = "top",
      legend.title = element_blank(),
      legend.margin = margin(b = -5),
      panel.grid.major = element_line(color = "#cccccc", size = 0.2),
      panel.grid.minor = element_blank(),
      plot.caption = element_text(size = 9, face = "italic", hjust = 0)
    )
  
  p <- ggplot(all_df, aes(x = date, y = value, color = type)) +
    geom_line(linewidth = 1.1) +
    facet_wrap(~window, ncol = 2) +
    scale_color_manual(values = color_map) +
    scale_y_continuous(labels = dollar_format(scale = 1e-6, suffix = "M")) +
    labs(
      title = paste("Dual Arbitrage Strategy vs Benchmarks ???", yr),
      subtitle = paste(tickerA, "vs", tickerB, "| Threshold ??", threshold),
      x = NULL, y = "Portfolio Value (USD)",
      caption = "Source: Yahoo Finance ?? Strategy: BuyPolar Capital"
    ) +
    theme_gs
  
  plot_list[[as.character(yr)]] <- p
}

# Output PDF
if (!dir.exists("plots")) dir.create("plots")
pdf("plots/dual_arbitrage_facet_BNS_BNSTO.pdf", width = 11, height = 8.5)
for (p in plot_list) print(p)
dev.off()
