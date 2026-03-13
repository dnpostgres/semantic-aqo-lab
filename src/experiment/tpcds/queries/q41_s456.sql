select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 695 and 695+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'rosy' or i_color = 'pale') and 
        (i_units = 'Ounce' or i_units = 'Bundle') and
        (i_size = 'N/A' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'yellow' or i_color = 'honeydew') and
        (i_units = 'Box' or i_units = 'Pallet') and
        (i_size = 'petite' or i_size = 'extra large')
        ) or
        (i_category = 'Men' and
        (i_color = 'blush' or i_color = 'plum') and
        (i_units = 'Dozen' or i_units = 'Gram') and
        (i_size = 'economy' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'beige' or i_color = 'burnished') and
        (i_units = 'Dram' or i_units = 'Bunch') and
        (i_size = 'N/A' or i_size = 'small')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'tan' or i_color = 'coral') and 
        (i_units = 'Tbl' or i_units = 'Tsp') and
        (i_size = 'N/A' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'spring' or i_color = 'cyan') and
        (i_units = 'Gross' or i_units = 'Each') and
        (i_size = 'petite' or i_size = 'extra large')
        ) or
        (i_category = 'Men' and
        (i_color = 'cream' or i_color = 'azure') and
        (i_units = 'Cup' or i_units = 'Pound') and
        (i_size = 'economy' or i_size = 'large')
        ) or
        (i_category = 'Men' and
        (i_color = 'antique' or i_color = 'navajo') and
        (i_units = 'N/A' or i_units = 'Lb') and
        (i_size = 'N/A' or i_size = 'small')
        )))) > 0
 order by i_product_name
 limit 100;

