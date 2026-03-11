-- TPC-DS Q65: Store revenue analysis
select s_store_name, i_item_desc, sc.revenue, i_current_price,
    i_wholesale_cost, i_brand
from store, item,
    (select ss_store_sk, ss_item_sk, sum(ss_sales_price) as revenue
     from store_sales, date_dim
     where ss_sold_date_sk = d_date_sk
         and d_month_seq between 1176 and 1176 + 11
     group by ss_store_sk, ss_item_sk) sc
where sc.ss_store_sk = s_store_sk
    and sc.ss_item_sk = i_item_sk
    and sc.revenue <= (
        select 0.1 * avg(revenue)
        from (select ss_store_sk, ss_item_sk, sum(ss_sales_price) as revenue
              from store_sales, date_dim
              where ss_sold_date_sk = d_date_sk
                  and d_month_seq between 1176 and 1176 + 11
              group by ss_store_sk, ss_item_sk) sb
        where sb.ss_store_sk = sc.ss_store_sk)
order by s_store_name, i_item_desc
limit 100;
