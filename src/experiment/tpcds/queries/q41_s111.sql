select  distinct(i_product_name)
 from item i1
 where i_manufact_id between 854 and 854+40 
   and (select count(*) as item_cnt
        from item
        where (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'azure' or i_color = 'goldenrod') and 
        (i_units = 'Tsp' or i_units = 'Each') and
        (i_size = 'extra large' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'ivory' or i_color = 'olive') and
        (i_units = 'Pallet' or i_units = 'Gram') and
        (i_size = 'petite' or i_size = 'economy')
        ) or
        (i_category = 'Men' and
        (i_color = 'powder' or i_color = 'linen') and
        (i_units = 'Box' or i_units = 'Carton') and
        (i_size = 'large' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'peru' or i_color = 'salmon') and
        (i_units = 'Tbl' or i_units = 'Pound') and
        (i_size = 'extra large' or i_size = 'small')
        ))) or
       (i_manufact = i1.i_manufact and
        ((i_category = 'Women' and 
        (i_color = 'metallic' or i_color = 'navajo') and 
        (i_units = 'Bunch' or i_units = 'Dram') and
        (i_size = 'extra large' or i_size = 'small')
        ) or
        (i_category = 'Women' and
        (i_color = 'lime' or i_color = 'tomato') and
        (i_units = 'Bundle' or i_units = 'Lb') and
        (i_size = 'petite' or i_size = 'economy')
        ) or
        (i_category = 'Men' and
        (i_color = 'chartreuse' or i_color = 'floral') and
        (i_units = 'N/A' or i_units = 'Cup') and
        (i_size = 'large' or i_size = 'medium')
        ) or
        (i_category = 'Men' and
        (i_color = 'dim' or i_color = 'blush') and
        (i_units = 'Ounce' or i_units = 'Unknown') and
        (i_size = 'extra large' or i_size = 'small')
        )))) > 0
 order by i_product_name
 limit 100;

